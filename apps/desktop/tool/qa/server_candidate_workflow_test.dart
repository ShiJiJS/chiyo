import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/credential_files.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_cli/device_credential_host.dart';

import '../../../server/test/support/tls_fixture.dart';
import '../../test/support/synthetic_backup_picker.dart';
import '../../test/support/desktop_platform_fixture.dart';

class _Http extends HttpOverrides {}

// Explicit opt-in QA runner. It never uses the daily App configuration.
String requiredPath(String name) {
  final value = Platform.environment[name];
  if (value == null || !value.startsWith('/')) {
    throw StateError('$name requires an absolute path');
  }
  return value;
}

final candidate = requiredPath('CHIYO_TEST_CANDIDATE');
final payload = '$candidate/macos/chiyo';
final evidence = requiredPath('CHIYO_TEST_EVIDENCE');
String? candidateCommit;
Future<String> docker(List<String> args) async {
  final r = await Process.run('/usr/local/bin/docker', args);
  if (r.exitCode != 0) {
    throw StateError(
      'Isolated docker operation failed: ${args.take(2).join(' ')}: ${r.stderr}',
    );
  }
  return '${r.stdout}'.trim();
}

class _Server {
  _Server(this.root, this.name, this.address, this.token, this.ca, this.client);
  final Directory root;
  final String name, token, ca;
  final Uri address;
  final OwnerClient client;
  Future<OwnerClient> connect() => OwnerClient.connect(
    address: address,
    token: token,
    trust: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(ca)),
  );
  static Future<_Server> make() async {
    final root = Directory(
      await (await Directory.systemTemp.createTemp(
        'chiyo-a12-candidate-',
      )).resolveSymbolicLinks(),
    );
    final name =
        'chiyo-a12-${root.uri.pathSegments.where((s) => s.isNotEmpty).last.toLowerCase()}';
    var started = false;
    try {
      final manifest = jsonDecode(
        await File('$candidate/candidate.json').readAsString(),
      );
      await docker([
        'run',
        '--rm',
        '--mount',
        'type=bind,source=${root.path},target=/fixture',
        manifest['serverTag'],
        'init-secrets',
        '/fixture/secrets',
      ]);
      final tls = await createTlsFixture(root);
      await File('${root.path}/server.json').writeAsString(
        jsonEncode({
          'dataDirectory': 'data',
          'secretsDirectory': 'secrets',
          'tlsCertificate': 'certificate.pem',
          'tlsPrivateKey': 'tls.key',
          'address': '0.0.0.0',
          'port': 47126,
        }),
      );
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      await docker([
        'run',
        '-d',
        '--name',
        name,
        '--mount',
        'type=bind,source=${root.path},target=/fixture',
        '-p',
        '127.0.0.1:$port:47126',
        manifest['serverTag'],
        'serve',
        '/fixture/server.json',
      ]);
      started = true;
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final ca = await File(tls.ca).readAsString(),
          address = Uri.parse('https://127.0.0.1:$port');
      OwnerClient? client;
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (client == null) {
        try {
          client = await OwnerClient.connect(
            address: address,
            token: token,
            trust: SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificatesBytes(utf8.encode(ca)),
          );
        } catch (_) {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return _Server(root, name, address, token, ca, client);
    } catch (_) {
      if (started) await docker(['rm', '-f', name]);
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> restart() async {
    await docker(['stop', '--time', '30', name]);
    expect(
      await docker(['inspect', '--format', '{{.State.ExitCode}}', name]),
      '0',
    );
    await docker(['start', name]);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        final c = await connect();
        c.close();
        return;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> close() async {
    client.close();
    await docker(['stop', '--time', '30', name]);
    await docker(['rm', name]);
    await root.delete(recursive: true);
  }
}

class _Files implements InformationFilePicker {
  String? next;
  @override
  Future<String?> choose() async => next;
  @override
  Future<String?> saveAs(String name) async => null;
}

class _Outputs extends SyntheticBackupPicker {
  String? fileOutput;
  @override
  Future<String?> ownerFileOutput(String name) async => fileOutput;
}

class _Cli {
  _Cli(this.path, this.association, this.chat);
  final String path, association, chat;
  static Future<_Cli> open(_Server f) async {
    final device = await f.client.request('POST', '/v1/owner/devices', {
      'operationId': 'candidate-device',
      'name': '合成候选工作流',
    });
    final profile = await AgentConnectionProfile(
      address: f.address,
      deviceToken: device['deviceToken'],
      serverId: f.client.serverId,
      certificate: f.ca,
    ).saveIn(Directory('${f.root.path}/agent-profile'));
    final prepared = '${f.root.path}/prepared';
    final p = await Process.run('$payload/cli/info-prepare-codex', [
      '--connection',
      profile.path,
      '--state-root',
      '${f.root.path}/chat-state',
      prepared,
    ]);
    expect(p.exitCode, 0, reason: '${p.stderr}');
    const chat = 'synthetic-a12-candidate-chat';
    final h = await Process.run(
      '$prepared/info-codex-hook',
      [
        '--connect',
        '--connection',
        profile.path,
        '--state-root',
        '${f.root.path}/chat-state',
      ],
      environment: {'CODEX_THREAD_ID': chat},
    );
    expect(h.exitCode, 0, reason: '${h.stderr}');
    final out = jsonDecode('${h.stdout}');
    final association =
        jsonDecode(
              out['hookSpecificOutput']['additionalContext'],
            )['association']
            as String;
    return _Cli('$prepared/info-codex', association, chat);
  }

  Future<void> close() async {
    final a = await CodexAssociation.load(association, chat);
    final host = DeviceCredentialHost(
      a.connection!,
      Directory('${File(association).parent.path}/device-files'),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final result = await host.stopIfIdle();
      if (result['status'] == 'ok') return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Candidate executor not idle; preserve fixture');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<Map<String, dynamic>> call(Map<String, Object?> command) async {
    final p = await Process.start(
      path,
      [],
      environment: {'CODEX_THREAD_ID': chat},
    );
    final output = p.stdout.transform(utf8.decoder).join(),
        error = p.stderr.transform(utf8.decoder).join();
    p.stdin.write(jsonEncode({'association': association, ...command}));
    await p.stdin.close();
    expect(await p.exitCode, 0, reason: await error);
    return jsonDecode(await output) as Map<String, dynamic>;
  }
}

Future<void> approve(RemoteWorkspaceSource s, String id) async {
  final detail = await s.approvals.read(id);
  final draft = ApprovalDraft(detail);
  await s.approvals.change(
    WorkspaceApprovalChange(
      operationId: workspaceOperationId(),
      requestId: id,
      reviewToken: detail.reviewToken,
      action: WorkspaceApprovalAction.approve,
      selected: draft.selected,
      fileVersions: {
        for (final scope in detail.scopes)
          if (scope.kind == WorkspaceApprovalScopeKind.file &&
              draft.selected.contains(scope.id) &&
              draft.files[scope.id] != null)
            scope.id: draft.files[scope.id]!,
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Server f;
  late _Files files;
  late _Outputs outputs;
  late RemoteWorkspaceSource s;
  late _Cli cli;
  final facts = <String, bool>{};
  int? expectedRecords;
  setUpAll(() async {
    HttpOverrides.global = _Http();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
        'This candidate runner validates the current Mac device',
      );
    }
    if (await Directory(evidence).exists()) {
      throw StateError('Choose a new evidence directory');
    }
    await Directory(evidence).create(recursive: true);
    final manifest = jsonDecode(
      await File('$candidate/candidate.json').readAsString(),
    );
    if (manifest['buildComplete'] != true) {
      throw StateError('Candidate build is incomplete');
    }
    candidateCommit = manifest['sourceCommit'] as String;
    final repo = (await Process.run('git', [
      'rev-parse',
      '--show-toplevel',
    ])).stdout.toString().trim();
    final unchanged = await Process.run('git', [
      '-C',
      repo,
      'diff',
      '--quiet',
      candidateCommit!,
      '--',
      'apps/desktop/lib',
      'apps/server/bin',
      'apps/server/lib',
      'packages/info_core/lib',
      'packages/info_storage/lib',
      'packages/info_workspace/lib',
      'packages/info_remote/lib',
      'packages/info_cli/lib',
      'packages/info_cli/bin',
      'integrations/codex',
      'third_party',
    ]);
    if (unchanged.exitCode != 0) {
      throw StateError('Current product source differs from the candidate');
    }
    final imageId = await docker([
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      manifest['serverTag'] as String,
    ]);
    if (imageId != manifest['serverImageId']) {
      throw StateError('Candidate image tag was changed');
    }
    await File('$evidence/workflow-facts.json').writeAsString(
      jsonEncode({
        'sourceCommit': candidateCommit,
        'complete': false,
        'checks': facts,
      }),
    );
    f = await _Server.make();
    files = _Files();
    outputs = _Outputs();
    s = RemoteWorkspaceSource(
      await f.connect(),
      deviceFilesDirectory: '${f.root.path}/app-files',
      filePicker: files,
      outputPicker: outputs,
    );
    cli = await _Cli.open(f);
  });
  tearDownAll(() async {
    await cli.close();
    await s.dispose();
    await f.close();
    HttpOverrides.global = null;
  });
  test(
    'same compiled Linux candidate + actual AOT Codex/worker complete continuous owner and Agent workflows',
    () async {
      debugPrint('Candidate stage: capabilities and prepared tools');
      final cap = await cli.call({'command': 'capabilities'});
      expect(cap['credentialToolScope'], 'current_device');
      expect(
        (cap['credentialTools'] as List).every((t) => t['available'] == true),
        true,
      );
      facts['matchedToolsAndPreparedBundle'] = true;
      final catalog = await s.loadCatalog();
      final dir = await s.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'candidate-dir',
          expectedVersion: catalog.version,
          action: WorkspaceDirectoryAction.create,
          name: '候选合成资料',
        ),
      );
      final definition = await s.loadTemplate('generic');
      final saved =
          await s.createRecord(
                WorkspaceCreate(
                  operationId: 'candidate-owner-create',
                  typeId: 'generic',
                  name: '连续试用资料',
                  directoryId: dir!.id,
                  expectedTemplateVersion:
                      definition['templateVersion'] as String,
                  expectedTemplateDigest: definition['packageDigest'] as String,
                  values: {'body': 'SYNTHETIC_CANDIDATE_V1'},
                ),
              )
              as WorkspaceSaved;
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'candidate-owner-edit',
          expectedVersion: 1,
          record: saved.detail.record,
          values: {...saved.detail.values, 'body': 'SYNTHETIC_CANDIDATE_V2'},
        ),
      );
      final record = (await f.client.information()).single;
      final req = await cli.call({
        'command': 'request',
        'operationId': 'candidate-read',
        'purpose': '合成流程读取',
        'fields': [
          {'itemId': record.id, 'fieldId': record.fields.single.id},
        ],
      });
      expect(req['status'], 'pending');
      await approve(s, req['requestId'] as String);
      final read = await cli.call({
        'command': 'read',
        'requestId': req['requestId'],
        'itemId': record.id,
        'fieldId': record.fields.single.id,
      });
      expect(jsonEncode(read), contains('SYNTHETIC_CANDIDATE_V2'));
      await f.restart();
      final afterRestart = await cli.call({
        'command': 'read',
        'requestId': req['requestId'],
        'itemId': record.id,
        'fieldId': record.fields.single.id,
      });
      expect(jsonEncode(afterRestart), contains('SYNTHETIC_CANDIDATE_V2'));
      facts['saveEditApprovalReadAndServerRestart'] = true;
      debugPrint(
        'Candidate stage: restart and read passed; whole proposal next',
      );
      final template =
          (await cli.call({
                'command': 'template-read',
                'templateId': 'document',
              }))['template']
              as Map;
      final example = Map<String, dynamic>.from(
        ((template['submissionExample'] as Map)['items'] as List).single,
      );
      final pending = await cli.call({
        'command': 'import-submit',
        'operationId': 'candidate-proposal',
        'agentName': '合成工作流',
        'purpose': '新增两份合成文档',
        'items': [
          {...example, 'key': 'doc-a', 'name': '候选合成文档甲'},
          {...example, 'key': 'doc-b', 'name': '候选合成文档乙'},
        ],
      });
      expect(pending['status'], 'pending');
      expect((await f.client.information()).length, 1);
      final proposal = ProposalsController(s.proposals, s.changes);
      await proposal.open(pending['proposalId'] as String);
      expect(proposal.canConfirm, true);
      await proposal.decide(WorkspaceProposalAction.confirm);
      expect(proposal.writeFailure, isNull);
      proposal.dispose();
      expect((await f.client.information()).length, 3);
      facts['dynamicTemplateAndWholeProposal'] = true;
      debugPrint('Candidate stage: proposal passed; files next');
      final original = File('${f.root.path}/original.md'),
          replacement = File('${f.root.path}/revision.md');
      await original.writeAsString('# 合成附件一\n\nSYNTHETIC_FILE_V1');
      await replacement.writeAsString('# 合成附件二\n\nSYNTHETIC_FILE_V2');
      files.next = original.path;
      final selected = (await s.files.pick())!;
      final file = await s.importFile(
        WorkspaceFileImport(
          operationId: 'candidate-file',
          selectionId: selected.selectionId,
          name: '候选合成附件',
        ),
      );
      files.next = replacement.path;
      final next = (await s.files.pick())!;
      await s.changeFile(
        WorkspaceFileChange(
          operationId: 'candidate-file-version',
          record: file,
          fieldKey: 'file',
          expectedRecordVersion: 1,
          expectedFileVersion: 1,
          kind: WorkspaceFileChangeKind.replace,
          selectionId: next.selectionId,
        ),
      );
      expect(
        (await s.readFilePreview(file, 'file', version: 1)).text,
        await original.readAsString(),
      );
      expect(
        (await s.readFilePreview(file, 'file', version: 2)).text,
        await replacement.readAsString(),
      );
      outputs.fileOutput = '${f.root.path}/user-save.md';
      expect(
        (await s.fileAction(
          file,
          'file',
          2,
          WorkspaceFileAction.saveAs,
          operationId: 'candidate-file-save',
        )).completed,
        true,
      );
      expect(
        await File(outputs.fileOutput!).readAsString(),
        await replacement.readAsString(),
      );
      final fileDetail = await s.readDetail(file),
          field = fileDetail.fieldIds['file']!;
      final fileReq = await cli.call({
        'command': 'request',
        'operationId': 'candidate-file-read',
        'purpose': '合成附件领取',
        'fields': [
          {'itemId': file.id, 'fieldId': field},
        ],
      });
      await approve(s, fileReq['requestId']);
      final fetched = await cli.call({
        'protocolVersion': 2,
        'command': 'file-fetch',
        'requestId': fileReq['requestId'],
        'itemId': file.id,
        'fieldId': field,
        'operationId': 'candidate-file-copy',
      });
      expect(fetched['status'], 'ok');
      final delivery = fetched['delivery'] as Map;
      expect(
        await File(delivery['path']).readAsString(),
        await replacement.readAsString(),
      );
      await cli.call({
        'protocolVersion': 2,
        'command': 'file-release',
        'deliveryId': delivery['deliveryId'],
      });
      final copy = File(delivery['path'] as String);
      final cleanupDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (await copy.exists() && DateTime.now().isBefore(cleanupDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await copy.exists(), false);
      facts['managedAttachmentPhysicalCleanup'] = true;
      facts['attachmentVersionsSaveAndActualCliDelivery'] = true;
      debugPrint('Candidate stage: files passed; actual credential tool next');
      final input = await s.credentials.file(
        SelectedCredentialFile(
          'credentials',
          utf8.encode(
            '[default]\naws_access_key_id=SYNTHETIC_CANDIDATE_KEY\naws_secret_access_key=SYNTHETIC_CANDIDATE_SECRET\n',
          ),
        ),
      );
      final credential = await s.credentials.save(
        WorkspaceCredentialWrite(
          operationId: 'candidate-credential',
          name: '候选合成AWS',
          purpose: '仅本机合成检查',
          candidateId: input.id,
          binding: 'aws_file',
          discoverable: true,
          linkedInformation: [file],
        ),
      );
      final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var signed = 0;
      final listening = endpoint.listen((request) async {
        final body = await request
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join();
        if (body.contains('GetCallerIdentity') &&
            (request.headers.value('authorization') ?? '').contains(
              'Credential=SYNTHETIC_CANDIDATE_KEY/',
            )) {
          signed++;
        }
        request.response.headers.contentType = ContentType('text', 'xml');
        request.response.write(
          '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult><Arn>arn:aws:iam::123456789012:user/synthetic</Arn><UserId>SYNTHETIC_USER</UserId><Account>123456789012</Account></GetCallerIdentityResult><ResponseMetadata><RequestId>synthetic-request</RequestId></ResponseMetadata></GetCallerIdentityResponse>',
        );
        await request.response.close();
      });
      try {
        final tool = (cap['credentialTools'] as List).cast<Map>().singleWhere(
          (e) => e['receiver'] == 'aws_shared_credentials',
        );
        final launch = {
          'receiver': 'aws_shared_credentials',
          'executable': tool['executable'],
          'argv': [
            'sts',
            'get-caller-identity',
            '--region',
            'us-east-1',
            '--endpoint-url',
            'http://127.0.0.1:${endpoint.port}',
            '--output',
            'json',
          ],
          'cwd': f.root.path,
          'env': {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'aws_file'},
          },
        };
        final requested = await cli.call({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': '合成AWS本机端点检查',
          'credentials': [
            {
              'alias': 'aws_file',
              'credentialId': credential.ref.id,
              'version': 1,
            },
          ],
          'launch': launch,
        });
        expect(requested['status'], 'pending');
        await approve(s, requested['requestId']);
        final launched = await cli.call({
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': requested['requestId'],
          'operationId': 'candidate-aws-once',
          'launch': launch,
        });
        expect(launched['status'], 'accepted');
        Map<String, dynamic> status = {};
        final end = DateTime.now().add(const Duration(seconds: 40));
        while (true) {
          status = await cli.call({
            'protocolVersion': 2,
            'command': 'execution-status',
            'executionId': launched['executionId'],
          });
          if (status['executionState'] == 'exited' &&
              status['cleanupState'] == 'complete') {
            break;
          }
          if (DateTime.now().isAfter(end)) {
            fail('Actual candidate AWS execution did not settle: $status');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(status['exitCode'], 0);
        expect(status['cleanupState'], 'complete');
        facts['credentialCleanupReportedComplete'] = true;
        expect(signed, 1);
        final again = await cli.call({
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': requested['requestId'],
          'operationId': 'candidate-aws-once',
          'launch': launch,
        });
        expect(again['duplicate'], true);
        expect(signed, 1);
        facts['actualBundledAwsAndWorkerCredentialExecution'] = true;
      } finally {
        await endpoint.close(force: true);
        await listening.cancel();
      }
      debugPrint(
        'Candidate stage: credential tool passed; directory/recycle next',
      );
      final currentCatalog = await s.loadCatalog();
      await s.changeClassification(
        WorkspaceTagChange(
          operationId: 'candidate-tag',
          expectedVersion: currentCatalog.version,
          action: WorkspaceTagAction.create,
          name: '合成检查',
        ),
      );
      final moving = WorkspaceLibrarySelection(records: [file]);
      final placement = await s.previewLibraryMove(moving, dir.id);
      await s.moveLibrarySelection(
        WorkspaceLibraryMoveCommand(
          operationId: 'candidate-move',
          selection: moving,
          targetId: dir.id,
          reviewToken: placement.token,
        ),
      );
      await s.saveLibrarySort(WorkspaceSort.manual);
      expect((await s.readDetail(file)).record.directoryId, dir.id);
      facts['directoryTagsMoveAndOrder'] = true;
      final selection = WorkspaceLibrarySelection(directoryIds: [dir.id]);
      final preview = await s.previewLibraryRecycle(selection);
      final recycled = await s.changeLibraryRecycle(
        WorkspaceLibraryRecycleCommand(
          operationId: 'candidate-recycle',
          reviewToken: preview.token,
          selection: selection,
        ),
      );
      final restore = await s.previewLibraryRecycleRestore(
        recycled.batchId,
        WorkspaceLibraryRestoreOptions(),
      );
      await s.changeLibraryRecycle(
        WorkspaceLibraryRecycleCommand(
          operationId: 'candidate-recycle-restore',
          reviewToken: restore.token,
          batchId: recycled.batchId,
        ),
      );
      expect(
        (await s.readFilePreview(file, 'file')).text,
        await replacement.readAsString(),
      );
      facts['recycleRestore'] = true;
      debugPrint('Candidate stage: recycle passed; encrypted backup next');
      outputs.keyOutput = '${f.root.path}/recovery.key';
      outputs.archiveOutput = '${f.root.path}/complete.aimbackup';
      final backup = BackupController(s.backups, s.changes);
      await backup.load();
      await backup.write(WorkspaceBackupAction.enableKey);
      await backup.pick(WorkspaceBackupPick.keyOutput, s.backups.pick);
      await backup.write(WorkspaceBackupAction.saveKey);
      await backup.pick(WorkspaceBackupPick.archiveOutput, s.backups.pick);
      await backup.write(WorkspaceBackupAction.export);
      expect(backup.failure, isNull);
      final counts = backup.result!.counts!;
      backup.dispose();
      final target = await _Server.make();
      try {
        final targetPicker = _Outputs()
          ..archiveInput = outputs.archiveOutput
          ..keyInput = outputs.keyOutput;
        final restored = RemoteWorkspaceSource(
          await target.connect(),
          deviceFilesDirectory: '${target.root.path}/app-files',
          outputPicker: targetPicker,
        );
        try {
          final model = BackupController(restored.backups, restored.changes);
          await model.load();
          await model.pick(
            WorkspaceBackupPick.archiveInput,
            restored.backups.pick,
          );
          await model.pick(WorkspaceBackupPick.keyInput, restored.backups.pick);
          await model.inspect();
          expect(model.failure, isNull);
          expect(model.preview!.counts.same(counts), true);
          await model.write(WorkspaceBackupAction.restore);
          expect(model.failure, isNull);
          model.dispose();
          expect(
            (await restored.loadSummary()).records,
            (await s.loadSummary()).records,
          );
          expect(
            (await restored.readFilePreview(file, 'file', version: 1)).text,
            await original.readAsString(),
          );
          expect(
            (await restored.credentials.read(credential.ref)).record.name,
            '候选合成AWS',
          );
        } finally {
          await restored.dispose();
        }
      } finally {
        await target.close();
      }
      facts['completeEncryptedBackupIntoFreshCompiledServer'] = true;
      final fresh = RemoteWorkspaceSource(
        await f.connect(),
        deviceFilesDirectory: '${f.root.path}/fresh-client',
      );
      try {
        expect(
          (await fresh.loadSummary()).records,
          (await s.loadSummary()).records,
        );
        expect(
          (await fresh.readDetail(saved.detail.record.ref)).values['body'],
          'SYNTHETIC_CANDIDATE_V2',
        );
        facts['freshClientFetch'] = true;
      } finally {
        await fresh.dispose();
      }
      expectedRecords = (await s.loadSummary()).records;
      await File('$evidence/workflow-facts.json').writeAsString(
        jsonEncode({
          'sourceCommit': candidateCommit,
          'complete':
              facts['normalOnlineLauncherAgainstCompiledServer'] == true,
          'checks': facts,
        }),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  testWidgets(
    'normal current-source App reconnects to this exact compiled candidate library',
    (t) async {
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrivateConnectionProfileStore profiles;
      await t.runAsync(() async {
        profiles = PrivateConnectionProfileStore('${f.root.path}/normal-ui');
        await profiles.save(
          ConnectionProfile(
            address: f.address.toString(),
            token: f.token,
            serverId: f.client.serverId,
            certificate: f.ca,
          ),
        );
      });
      debugPrint('Candidate UI stage: mounting normal launcher');
      await t.pumpWidget(
        OnlineDesktopLauncher(
          profiles: profiles,
          desktopPlatform: NativeDesktopFixture(),
        ),
      );
      for (
        var n = 0;
        n < 300 && find.byType(WorkspaceApp).evaluate().isEmpty;
        n++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      debugPrint('Candidate UI stage: launcher waited');
      expect(find.byType(WorkspaceApp), findsOneWidget);
      for (var n = 0; n < 250 && find.text('连续试用资料').evaluate().isEmpty; n++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('连续试用资料'), findsWidgets);
      final appSource =
          t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
              as RemoteWorkspaceSource;
      int? observedRecords;
      Object? summaryError;
      var summaryDone = false;
      await t.runAsync(() async {
        appSource.loadSummary().then(
          (v) {
            observedRecords = v.records;
            summaryDone = true;
          },
          onError: (Object e) {
            summaryError = e;
            summaryDone = true;
          },
        );
      });
      for (var n = 0; n < 300 && !summaryDone; n++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 40));
      }
      expect(summaryDone, true);
      expect(summaryError, isNull);
      expect(observedRecords, expectedRecords);
      debugPrint('Candidate UI stage: unmounting');
      await t.pumpWidget(const SizedBox());
      debugPrint('Candidate UI stage: closing source');
      var sourceClosed = false;
      Object? closeError;
      await t.runAsync(() async {
        appSource.dispose().then(
          (_) => sourceClosed = true,
          onError: (Object e) {
            closeError = e;
            sourceClosed = true;
          },
        );
      });
      for (var n = 0; n < 300 && !sourceClosed; n++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 40));
      }
      expect(
        sourceClosed,
        true,
        reason:
            'UI source disposal must settle while pumping its original widget zone',
      );
      expect(closeError, isNull);
      await t.pump();
      facts['normalOnlineLauncherAgainstCompiledServer'] = true;
      await t.runAsync(
        () => File('$evidence/workflow-facts.json').writeAsString(
          jsonEncode({
            'sourceCommit': candidateCommit,
            'complete':
                facts['normalOnlineLauncherAgainstCompiledServer'] == true,
            'checks': facts,
          }),
        ),
      );
    },
  );
}
