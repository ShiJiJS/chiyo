import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/device_credential_journal.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/device_test_receiver.dart';

// Permissionless synthetic receivers, not the real gh/aws clients. The real
// device preflight, native process worker, server approval, journal, output
// filtering and file cleanup are used without injecting a process starter.
Future<void> _until(Future<bool> Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!await done()) {
    if (DateTime.now().isAfter(end))
      fail('Original native execution did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  for (final scenario in [
    'token',
    'file',
    'file-supervisor-crash',
    'token-lost-claim',
  ]) {
    final file = scenario.startsWith('file');
    final lost = scenario == 'token-lost-claim';
    final crash = scenario == 'file-supervisor-crash';
    test(
      'normal remote CLI $scenario on Mac uses original native worker without App',
      () async {
        final f = await DeviceCredentialFixture.create(loseFirstClaim: lost);
        final root = Directory(await f.root.resolveSymbolicLinks());
        final work = await Directory('${root.path}/device-work').create();
        final counter = File('${work.path}/counter');
        final release = File('${work.path}/release');
        final executable = File('${work.path}/${file ? 'aws' : 'gh'}');
        await executable.writeAsString(
          syntheticCredentialReceiver,
          flush: true,
        );
        expect(
          (await Process.run('/bin/chmod', ['700', executable.path])).exitCode,
          0,
        );
        final client = AgentClient.remote(
          f.profiles.first,
          requireSubmissionMetadata: true,
          sourceAgent: 'Synthetic credential Agent',
          externalChatId: 'synthetic-credential-chat',
          deviceFileStateDirectory: Directory(
            '${root.path}/device-private/device-files',
          ),
        );
        addTearDown(() async {
          // Release this exact original receiver even if an assertion failed.
          await release.writeAsString('release');
          await client.drainCredentialExecutions();
          client.close();
          await f.dispose();
        });
        final credential = await f.runtime.run(() async {
          final raw = file
              ? await f.runtime.service.owner.createFileCredential(
                  name: 'Synthetic device file',
                  publicPurpose: '',
                  fileName: 'credentials',
                  bytes: utf8.encode(
                    '[default]\naws_access_key_id=SYNTHETIC_DEVICE_FILE\naws_secret_access_key=SYNTHETIC_DEVICE_FILE_SECRET\n',
                  ),
                )
              : await f.runtime.service.owner.createStringCredential(
                  name: 'Synthetic device token',
                  publicPurpose: '',
                  secret: 'SYNTHETIC_DEVICE_TOKEN',
                );
          return f.runtime.service.owner.updateCredentialMetadata(
            raw.id,
            raw.revision,
            name: raw.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'material',
            discoverable: true,
          );
        });
        expect(
          (await client.openLifecycleSession(
            'Synthetic native device chat',
          ))['status'],
          'ok',
        );
        final launch = <String, dynamic>{
          'receiver': file ? 'aws_shared_credentials' : 'gh_token',
          'executable': executable.path,
          'argv': [
            file ? 'sts' : 'api',
            file ? 'get-caller-identity' : 'user',
            counter.path,
            release.path,
            if (file) ...['--region', 'us-east-1'],
          ],
          'cwd': work.path,
          'env': {
            if (file)
              'AWS_SHARED_CREDENTIALS_FILE': {'file': 'material'}
            else
              'GH_TOKEN': {'secret': 'material'},
          },
        };
        final requested = await client.execute({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic native receiver only',
          'credentials': [
            {'alias': 'material', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': launch,
        });
        expect(requested['status'], 'pending', reason: jsonEncode(requested));
        final request = requested['requestId'] as String;
        final detail = approvalDetailFromJson(
          await f.owner.request('GET', '/v1/owner/approvals/details/$request'),
        );
        expect(detail.request.agentClaim, 'Synthetic credential Agent');
        expect(detail.request.chatClaim, contains('synthetic-credential-chat'));
        await f.owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'native-approve',
              requestId: request,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: detail.scopes.map((s) => s.id),
              credentialMinutes: 15,
            ),
          ),
        );
        final operation = <String, dynamic>{
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': request,
          'operationId': 'native-once',
          'launch': launch,
        };
        if (scenario == 'token') await f.reopen();
        final savedApproval = approvalDetailFromJson(
          await f.owner.request('GET', '/v1/owner/approvals/details/$request'),
        );
        expect(savedApproval.request.agentClaim, 'Synthetic credential Agent');
        expect(
          savedApproval.request.chatClaim,
          contains('synthetic-credential-chat'),
        );
        final history = grantResultsFromJson(
          await f.owner.request(
            'POST',
            '/v1/owner/grant-history/query',
            grantQueryToJson(const WorkspaceGrantQuery()),
          ),
        );
        final recorded = history.items.singleWhere(
          (h) => h.requestId == request,
        );
        expect(recorded.agentClaim, 'Synthetic credential Agent');
        expect(recorded.chatClaim, contains('synthetic-credential-chat'));
        Process? child;
        final childOutput = <String>[];
        final childErrors = <String>[];
        Map<String, dynamic> accepted;
        if (crash) {
          child = await Process.start(Platform.resolvedExecutable, [
            '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
            File('test/support/device_execution_child.dart').absolute.path,
          ]);
          child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(childOutput.add);
          child.stderr.transform(utf8.decoder).listen(childErrors.add);
          child.stdin.write(
            jsonEncode({
              'connection': f.profiles.first.toPrivateJson(),
              'sessionSecret': client.sessionSecret,
              'deviceFiles': '${root.path}/device-private/device-files',
              'operation': operation,
            }),
          );
          await child.stdin.close();
          await _until(() async => childOutput.isNotEmpty);
          accepted = jsonDecode(childOutput.first) as Map<String, dynamic>;
        } else {
          accepted = await client.execute(operation);
        }
        if (lost) {
          expect(
            accepted['errorCode'],
            'material_claim_failed',
            reason: jsonEncode(accepted),
          );
          expect(accepted['operationClaimed'], true);
          expect(f.repo.credentialExecutions, hasLength(1));
          final original = f.repo.credentialExecutions.single.id;
          expect(await counter.exists(), false);
          await f.reopen();
          final retried = await client.execute(operation);
          expect(retried['executionId'], original);
          expect(retried['duplicate'], true);
          expect(await counter.exists(), false);
          expect(f.repo.credentialExecutions, hasLength(1));
          return;
        }
        expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
        final id = accepted['executionId'] as String;
        await _until(counter.exists);
        final journalDir = Directory(
          '${root.path}/device-private/credential-executions',
        );
        final journals = await journalDir
            .list()
            .where((e) => e.path.endsWith('.json'))
            .toList();
        expect(journals, hasLength(1));
        final saved = await File(journals.single.path).readAsString();
        expect(saved, isNot(contains(client.sessionSecret!)));
        expect(saved, isNot(contains('SYNTHETIC_DEVICE_TOKEN')));
        expect(saved, isNot(contains('SYNTHETIC_DEVICE_FILE_SECRET')));
        expect((await File(journals.single.path).stat()).mode & 0xE3F, 0);
        String? materialPath;
        if (file) {
          await _until(File('${counter.path}.material-path').exists);
          materialPath = await File(
            '${counter.path}.material-path',
          ).readAsString();
          expect(await File(materialPath).exists(), true);
          expect(f.repo.credentialExecutions.single.materialLease, isNull);
        }
        if (crash) {
          expect(child!.kill(ProcessSignal.sigkill), true);
          await child.exitCode;
          final journal = DeviceCredentialJournal(f.profiles.first, journalDir);
          await journal.maintain();
          expect(
            await File(materialPath!).exists(),
            true,
            reason:
                'A dead CLI must not delete material while its native process group is active',
          );
          expect(f.repo.credentialExecutions.single.state, 'running');
          await release.writeAsString('release');
          await _until(() async {
            await journal.maintain();
            return f.repo.credentialExecutions.single.cleanupState ==
                'complete';
          });
          expect(
            f.repo.credentialExecutions.single.state,
            'unknown',
            reason: 'A dead process group does not prove the command exit code',
          );
          expect(await File(materialPath).exists(), false);
          expect(
            await journalDir
                .list()
                .where((e) => e.path.endsWith('.json'))
                .toList(),
            isEmpty,
          );
          final duplicate = await client.execute(operation);
          expect(duplicate['executionId'], id);
          expect(duplicate['executionState'], 'unknown');
          expect(await counter.readAsLines(), ['started']);
          expect(f.repo.credentialExecutions, hasLength(1));
          expect(
            childOutput.join(),
            isNot(contains('SYNTHETIC_DEVICE_FILE_SECRET')),
          );
          expect(
            childErrors.join(),
            isNot(contains('SYNTHETIC_DEVICE_FILE_SECRET')),
          );
          return;
        }
        // The same operation remains readable through a real server reopen.
        await f.reopen();
        final repeated = await client.execute(operation);
        expect(repeated['executionId'], id);
        expect(repeated['duplicate'], true);
        expect(await counter.readAsLines(), ['started']);
        await release.writeAsString('release');
        await client.drainCredentialExecutions();
        final status = await client.execute({
          'command': 'execution-status',
          'executionId': id,
        });
        expect(status['executionState'], 'exited', reason: jsonEncode(status));
        expect(status['exitCode'], 0, reason: jsonEncode(status));
        expect(status['cleanupState'], file ? 'complete' : 'not_needed');
        expect(
          await journalDir
              .list()
              .where((e) => e.path.endsWith('.json'))
              .toList(),
          isEmpty,
        );
        if (materialPath != null)
          expect(await File(materialPath).exists(), false);
        final output = await client.execute({
          'command': 'execution-output',
          'executionId': id,
        });
        expect(output['status'], 'ok', reason: jsonEncode(output));
        final text = utf8.decode(
          (output['chunks'] as List)
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList(),
        );
        expect(text, contains('CWD=${work.path}'));
        expect(text, contains('completed'));
        expect(text, isNot(contains('SYNTHETIC_DEVICE_TOKEN')));
        expect(text, isNot(contains('SYNTHETIC_DEVICE_FILE_SECRET')));
        expect(f.repo.credentialExecutions, hasLength(1));
      },
      skip: !Platform.isMacOS,
    );
  }
}
