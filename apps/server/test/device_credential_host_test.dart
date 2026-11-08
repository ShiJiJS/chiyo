import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_cli/device_credential_host.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/device_test_receiver.dart';

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline))
      fail('Original device Host did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<Map<String, dynamic>> _codex(
  String reference,
  String chat,
  Map<String, dynamic> command,
  List<Process> children,
) async {
  final standalone = Platform.environment['CHIYO_TEST_CODEX_EXECUTABLE'];
  final process = await Process.start(
    standalone ?? Platform.resolvedExecutable,
    [
      if (standalone == null) ...[
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        File('../../packages/info_cli/bin/codex_info.dart').absolute.path,
      ],
    ],
    environment: {
      'CODEX_THREAD_ID': chat,
      'HOME': File(reference).parent.path,
      'TMPDIR': Directory.systemTemp.path,
      'PATH': '/usr/bin:/bin',
    },
    includeParentEnvironment: false,
  );
  children.add(process);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(jsonEncode({'association': reference, ...command}));
  await process.stdin.close();
  // A timeout observes this same process; teardown releases its exact receiver.
  expect(await process.exitCode.timeout(const Duration(seconds: 25)), 0);
  expect(await errors, isEmpty);
  return jsonDecode(await output) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _hostRecord(Directory folder) async {
  final entries = await folder
      .list()
      .where((e) => e.path.endsWith('.json'))
      .toList();
  expect(entries, hasLength(1));
  final file = File(entries.single.path);
  expect((await file.stat()).mode & 0xE3F, 0);
  return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
}

Future<int> _raw(
  Map<String, dynamic> record, {
  bool origin = false,
  bool wrongProof = false,
}) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:${record['port']}/execute'),
    );
    request.headers.set(
      'authorization',
      wrongProof ? 'Bearer wrong' : 'Bearer ${record['controlCapability']}',
    );
    if (origin) request.headers.set('origin', 'https://untrusted.example');
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    http.close(force: true);
  }
}

// Drop only the calling CLI's response after the real resident executor has
// accepted the operation. No product test switch or alternate launch path.
Future<Map<String, dynamic>> _loseHostReply(
  Map<String, dynamic> record,
  File locator,
  Future<Map<String, dynamic>> Function() action,
) async {
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final http = HttpClient();
  Map<String, dynamic>? accepted;
  proxy.listen((incoming) async {
    try {
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${record['port']}/execute'),
      );
      request.headers.set(
        'authorization',
        incoming.headers.value('authorization')!,
      );
      await request.addStream(incoming);
      final response = await request.close();
      accepted =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      (await incoming.response.detachSocket(writeHeaders: false)).destroy();
    } on Object {
      try {
        await incoming.response.close();
      } on Object {
        /* disconnected */
      }
    }
  });
  try {
    await writePrivateDeviceState(locator, {...record, 'port': proxy.port});
    final result = await action();
    expect(accepted?['status'], 'accepted', reason: jsonEncode(accepted));
    return result;
  } finally {
    await writePrivateDeviceState(locator, record);
    await proxy.close(force: true);
    http.close(force: true);
  }
}

void main() {
  for (final file in [false, true]) {
    test(
      'separate normal Codex commands share one remote ${file ? 'file' : 'token'} executor, output and original grant without App',
      () async {
        final f = await DeviceCredentialFixture.create();
        final root = Directory(await f.root.resolveSymbolicLinks());
        final work = await Directory('${root.path}/device-work').create();
        final folder = Directory('${root.path}/codex');
        final deviceFiles = Directory('${folder.path}/device-files');
        final host = DeviceCredentialHost(f.profiles.first, deviceFiles);
        final release = File('${work.path}/release');
        final counter = File('${work.path}/counter');
        final executable = File('${work.path}/${file ? 'aws' : 'gh'}');
        await executable.writeAsString(syntheticCredentialReceiver);
        expect(
          (await Process.run('/bin/chmod', ['700', executable.path])).exitCode,
          0,
        );
        final bootstrap = AgentClient.remote(f.profiles.first);
        final children = <Process>[];
        addTearDown(() async {
          await release.writeAsString('release');
          for (final child in children) {
            await child.exitCode;
          }
          await _until(() async => (await host.stopIfIdle())['status'] == 'ok');
          if (await host.directory.exists()) {
            final record = await _hostRecord(host.directory);
            await _until(
              () async =>
                  CredentialProcessIdentity.isActive(
                    record['workerPid'] as int,
                    record['workerIdentity'] as String,
                  ) ==
                  false,
            );
          }
          bootstrap.close();
          await f.dispose();
        });
        expect(
          (await bootstrap.openLifecycleSession(
            'Synthetic one-command Codex',
          ))['status'],
          'ok',
        );
        const chat = 'synthetic-native-host-chat';
        final association = await CodexAssociation(
          chat,
          f.server.port,
          bootstrap.sessionSecret!,
          connection: f.profiles.first,
        ).save(folder);
        final credential = await f.runtime.run(() async {
          final raw = file
              ? await f.runtime.service.owner.createFileCredential(
                  name: 'Synthetic file',
                  publicPurpose: '',
                  fileName: 'credentials',
                  bytes: utf8.encode(
                    '[default]\naws_access_key_id=SYNTHETIC_DEVICE_FILE\naws_secret_access_key=SYNTHETIC_DEVICE_FILE_SECRET\n',
                  ),
                )
              : await f.runtime.service.owner.createStringCredential(
                  name: 'Synthetic token',
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
        final launch = <String, dynamic>{
          'receiver': file ? 'aws_shared_credentials' : 'gh_token',
          'executable': executable.path,
          'cwd': work.path,
          'argv': [
            file ? 'sts' : 'api',
            file ? 'get-caller-identity' : 'user',
            counter.path,
            release.path,
            if (file) ...['--region', 'us-east-1'],
          ],
          'env': {
            if (file)
              'AWS_SHARED_CREDENTIALS_FILE': {'file': 'material'}
            else
              'GH_TOKEN': {'secret': 'material'},
          },
        };
        final requested = await _codex(association, chat, {
          'command': 'request-use',
          'purpose': 'Synthetic normal one-command receiver',
          'credentials': [
            {'alias': 'material', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': launch,
        }, children);
        expect(requested['status'], 'pending', reason: jsonEncode(requested));
        final request = requested['requestId'] as String;
        final detail = approvalDetailFromJson(
          await f.owner.request('GET', '/v1/owner/approvals/details/$request'),
        );
        await f.owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'approve-hosted',
              requestId: request,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: detail.scopes.map((s) => s.id),
              credentialMinutes: 15,
            ),
          ),
        );
        Map<String, dynamic> operation(String id) => {
          'command': 'run-use',
          'requestId': request,
          'operationId': id,
          'launch': launch,
        };
        // Two actual adapter processes race the very first Host startup/operation.
        final racing = await Future.wait([
          _codex(association, chat, operation('once'), children),
          _codex(association, chat, operation('once'), children),
        ]);
        expect(
          racing.where((r) => r['status'] == 'accepted'),
          hasLength(1),
          reason: jsonEncode(racing),
        );
        final id =
            racing.singleWhere((r) => r['status'] == 'accepted')['executionId']
                as String;
        expect(
          racing.every((r) => r['executionId'] == id),
          true,
          reason: jsonEncode(racing),
        );
        await _until(counter.exists);
        final record = await _hostRecord(host.directory);
        if (Platform.environment['CHIYO_TEST_CODEX_EXECUTABLE'] != null) {
          final program = await Process.run('/bin/ps', [
            '-p',
            '${record['workerPid']}',
            '-o',
            'comm=',
          ]);
          expect('${program.stdout}', contains('info-runtime-worker'));
          expect('${program.stdout}', isNot(contains('/dart')));
        }
        expect(await _raw(record, origin: true), 403);
        expect(await _raw(record, wrongProof: true), 403);
        expect(jsonEncode(record), isNot(contains(bootstrap.sessionSecret!)));
        expect(jsonEncode(record), isNot(contains('SYNTHETIC_DEVICE_TOKEN')));
        expect(
          jsonEncode(record),
          isNot(contains('SYNTHETIC_DEVICE_FILE_SECRET')),
        );
        expect((await host.stopIfIdle())['errorCode'], 'cleanup_busy');
        expect(await counter.readAsLines(), ['started']);
        // Missing disk metadata cannot authorize replacing a live daemon.
        final locator = File(
          (await host.directory
                  .list()
                  .where((e) => e.path.endsWith('.json'))
                  .single)
              .path,
        );
        await locator.delete();
        Map<String, dynamic> missing;
        try {
          missing = await _codex(
            association,
            chat,
            operation('must-not-start'),
            children,
          );
        } finally {
          await writePrivateDeviceState(locator, record);
        }
        expect(
          missing['errorCode'],
          'material_claim_failed',
          reason: jsonEncode(missing),
        );
        expect(missing['operationClaimed'], true);
        expect(f.repo.credentialExecutions, hasLength(1));
        expect(
          CredentialProcessIdentity.isActive(
            record['workerPid'] as int,
            record['workerIdentity'] as String,
          ),
          true,
        );
        final live = await _codex(association, chat, {
          'command': 'execution-status',
          'executionId': id,
        }, children);
        expect(live['executionState'], 'running', reason: jsonEncode(live));
        expect(live['outputAvailable'], true);
        final other = AgentClient.remote(f.profiles.first);
        try {
          await other.openLifecycleSession('Synthetic unrelated chat');
          final wrong = AgentClient.remote(
            f.profiles.first,
            sessionSecret: other.sessionSecret,
            hostedCredentialExecutions: true,
            deviceFileStateDirectory: deviceFiles,
          );
          try {
            expect(
              (await wrong.execute({
                'command': 'execution-output',
                'executionId': id,
              }))['status'],
              isNot('ok'),
            );
          } finally {
            wrong.close();
          }
        } finally {
          other.close();
        }
        await f.reopen();
        final lost = await _loseHostReply(
          record,
          locator,
          () => _codex(association, chat, operation('second'), children),
        );
        expect(
          lost['errorCode'],
          'material_claim_failed',
          reason: jsonEncode(lost),
        );
        expect(lost['operationClaimed'], true);
        final next = await _codex(
          association,
          chat,
          operation('second'),
          children,
        );
        expect(next['duplicate'], true, reason: jsonEncode(next));
        await _until(() async => (await counter.readAsLines()).length == 2);
        expect(
          (await _hostRecord(host.directory))['workerPid'],
          record['workerPid'],
        );
        expect(f.repo.credentialExecutions, hasLength(2));
        int? offlinePort;
        final journals = Directory('${folder.path}/credential-executions');
        if (file) {
          offlinePort = f.server.port;
          await f.close();
        }
        await release.writeAsString('release');
        if (offlinePort != null) {
          // Finishing an admitted process must physically remove material even
          // while the information service is down. Preserve the exact terminal
          // report and cleanup proof until the original server returns.
          await _until(() async {
            final pending = await journals
                .list()
                .where((e) => e.path.endsWith('.json'))
                .toList();
            if (pending.length != 2) return false;
            for (final entry in pending) {
              final saved =
                  jsonDecode(await File(entry.path).readAsString()) as Map;
              if (saved['cleaned'] != true) return false;
              final lease = saved['lease'] as Map?;
              if (lease != null &&
                  await Directory(lease['path'] as String).exists())
                return false;
              expect((saved['report'] as Map)['executionState'], 'exited');
            }
            return true;
          });
          await f.open(offlinePort);
          // A normal adapter query also maintains these exact private receipts.
          final recovered = await _codex(association, chat, {
            'command': 'execution-status',
            'executionId': id,
          }, children);
          expect(
            recovered['executionState'],
            'exited',
            reason: jsonEncode(recovered),
          );
          expect(recovered['cleanupState'], 'complete');
        }
        await _until(
          () async => f.repo.credentialExecutions.every(
            (e) =>
                e.state == 'exited' &&
                const {'complete', 'not_needed'}.contains(e.cleanupState),
          ),
        );
        final output = await _codex(association, chat, {
          'command': 'execution-output',
          'executionId': id,
        }, children);
        expect(output['status'], 'ok', reason: jsonEncode(output));
        final text = utf8.decode(
          (output['chunks'] as List)
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList(),
        );
        expect(text, contains('completed'));
        expect(text, contains('CWD=${work.path}'));
        expect(text, isNot(contains('SYNTHETIC_DEVICE_TOKEN')));
        expect(text, isNot(contains('SYNTHETIC_DEVICE_FILE_SECRET')));
        final repeated = await _codex(
          association,
          chat,
          operation('once'),
          children,
        );
        expect(repeated['executionId'], id);
        expect(repeated['duplicate'], true);
        expect(await counter.readAsLines(), ['started', 'started']);
        expect(f.runtime.service.owner.credentialUseRequests, hasLength(1));
        expect(
          await journals.list().where((e) => e.path.endsWith('.json')).toList(),
          isEmpty,
        );
      },
      skip: !Platform.isMacOS,
    );
  }
}
