import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'formal CLI and Codex processes use a restricted remote device through restart and root end',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-remote-cli-');
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final ownerToken = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      var repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/data',
        keys,
      );
      var runtime = await OnlineInformationRuntime.open(repository: repo);
      var server = await OnlineServer.start(
        runtime: runtime,
        devices: AgentDeviceRegistry(repo),
        tls: tls,
        ownerToken: ownerToken,
        serverId: 'remote-cli-synthetic-server',
      );
      final port = server.port;
      final address = Uri.parse('https://127.0.0.1:$port');
      var owner = await OwnerClient.connect(
        address: address,
        token: ownerToken,
        trust: trust,
      );
      final cliDirectory = Directory('../../packages/info_cli').absolute;
      Future<List<Map<String, dynamic>>> invoke(
        String entry,
        List<Map<String, Object?>> inputs, {
        List<String> args = const [],
        String chat = 'synthetic-root',
      }) async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', 'bin/$entry.dart', ...args],
          workingDirectory: cliDirectory.path,
          environment: {'CODEX_THREAD_ID': chat},
        );
        final output = utf8.decoder.bind(process.stdout).join();
        final errors = utf8.decoder.bind(process.stderr).join();
        try {
          for (final input in inputs) process.stdin.writeln(jsonEncode(input));
          await process.stdin.close();
          expect(
            await process.exitCode.timeout(const Duration(seconds: 25)),
            0,
            reason: 'CLI process exit',
          );
          final text = await output;
          await errors;
          return const LineSplitter()
              .convert(text.trim())
              .map((v) => jsonDecode(v) as Map<String, dynamic>)
              .toList();
        } finally {
          process.kill();
        }
      }

      Future<Map<String, dynamic>> command(
        String reference,
        String name,
        Map<String, Object?> input, {
        String chat = 'synthetic-root',
      }) async => (await invoke('codex_info', [
        {'association': reference, 'command': name, ...input},
      ], chat: chat)).single;
      try {
        final item = await runtime.run(
          () => runtime.service.owner.createInformation(
            'Synthetic remote server',
            'Remote CLI proof',
            [
              const FieldInput('Address', '', 'SYNTHETIC_SELECTED_VALUE'),
              const FieldInput('Account', '', 'SYNTHETIC_UNSELECTED_VALUE'),
            ],
          ),
        );
        final enrolled = await owner.request('POST', '/v1/owner/devices', {
          'operationId': 'cli-enrollment',
          'name': 'Synthetic CLI',
        });
        final profile = AgentConnectionProfile(
          address: address,
          deviceToken: enrolled['deviceToken'] as String,
          serverId: owner.serverId,
          certificate: await File(fixture.ca).readAsString(),
        );
        final connectionFile = await profile.saveIn(
          Directory('${root.path}/connection'),
        );
        final discovery = await invoke(
          'info',
          [
            {'command': 'capabilities'},
            {'command': 'directory-list'},
            {'command': 'catalog'},
          ],
          args: ['--connection', connectionFile.path],
        );
        expect(discovery, hasLength(3));
        expect(discovery.every((r) => r['status'] == 'ok'), isTrue);
        expect(
          jsonEncode(discovery).contains('SYNTHETIC_SELECTED_VALUE'),
          isFalse,
        );
        final start = (await invoke(
          'codex_hook',
          [
            {
              'hook_event_name': 'SessionStart',
              'source': 'startup',
              'session_id': 'synthetic-root',
            },
          ],
          args: [
            '--connection',
            connectionFile.path,
            '--state-root',
            '${root.path}/state',
          ],
        )).single;
        final reference =
            jsonDecode(
                  start['hookSpecificOutput']['additionalContext'] as String,
                )['association']
                as String;
        final requestedFields = [
          for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
        ];
        final input = {
          'operationId': 'request-once',
          'purpose': 'Verify selected fields',
          'fields': requestedFields,
        };
        final pending = await command(reference, 'request', input);
        final requestId = pending['requestId'] as String;
        expect(pending['status'], 'pending');
        expect(
          (await command(reference, 'request', input))['requestId'],
          requestId,
        );
        expect(
          (await command(reference, 'request-status', {
            'operationId': 'request-once',
          }))['requestId'],
          requestId,
        );
        expect(
          (await command(reference, 'wait', {
            'requestId': requestId,
            'timeoutMs': 10,
          }))['waitTimedOut'],
          isTrue,
        );
        expect(
          (await command(reference, 'read', {
            'requestId': requestId,
            'itemId': item.id,
            'fieldId': item.fields.first.id,
          }))['status'],
          'pending',
        );
        final review = approvalDetailFromJson(
          await owner.request(
            'GET',
            '/v1/owner/approvals/${Uri.encodeComponent(requestId)}',
          ),
        );
        final decision = WorkspaceApprovalChange(
          operationId: 'approve-cli',
          requestId: requestId,
          reviewToken: review.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: [review.scopes.first.id],
          fieldMinutes: 10,
        );
        await owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(decision),
        );
        expect(
          (await command(reference, 'wait', {
            'requestId': requestId,
            'timeoutMs': 1000,
          }))['status'],
          'approved',
        );
        final claimed = await command(reference, 'claim', {
          'requestId': requestId,
        });
        expect(claimed['status'], 'ok');
        expect(claimed.containsKey('token'), isFalse);
        expect(claimed.containsKey('sessionSecret'), isFalse);
        Future<Map<String, dynamic>> read(
          String ref, {
          String chat = 'synthetic-root',
          bool other = false,
        }) => command(ref, 'read', {
          'requestId': requestId,
          'itemId': item.id,
          'fieldId': other ? item.fields.last.id : item.fields.first.id,
        }, chat: chat);
        expect((await read(reference))['value'], 'SYNTHETIC_SELECTED_VALUE');
        expect((await read(reference, other: true))['status'], 'unauthorized');
        final delegated = await command(reference, 'delegate', {
          'childChatId': 'synthetic-child',
        });
        final child = delegated['privateAssociation'] as String;
        expect(
          (await read(child, chat: 'synthetic-child'))['value'],
          'SYNTHETIC_SELECTED_VALUE',
        );
        expect(
          (await read(reference, chat: 'synthetic-other'))['status'],
          'association_unavailable',
        );
        final childEnd = (await invoke(
          'codex_hook',
          [
            {'hook_event_name': 'SessionEnd', 'session_id': 'synthetic-child'},
          ],
          args: ['--state-root', '${root.path}/state'],
        )).single;
        expect(childEnd['systemMessage'], contains('no_active_session'));
        expect((await read(reference))['status'], 'ok');
        owner.close();
        await server.close();
        await runtime.close();
        await repo.close();
        repo = await EncryptedInformationRepository.openOnline(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: ownerToken,
          serverId: 'remote-cli-synthetic-server',
          port: port,
        );
        owner = await OwnerClient.connect(
          address: address,
          token: ownerToken,
          trust: trust,
        );
        expect((await read(reference))['value'], 'SYNTHETIC_SELECTED_VALUE');
        expect(
          (await read(child, chat: 'synthetic-child'))['value'],
          'SYNTHETIC_SELECTED_VALUE',
        );
        expect(repo.grantHistory, hasLength(1));
        // Existing associations and end records pin their own original device and
        // server. Removing the bootstrap file cannot redirect or orphan them.
        await connectionFile.delete();
        final ended = (await invoke(
          'codex_hook',
          [
            {'hook_event_name': 'SessionEnd', 'session_id': 'synthetic-root'},
          ],
          args: [
            '--connection',
            connectionFile.path,
            '--state-root',
            '${root.path}/state',
          ],
        )).single;
        expect(ended['systemMessage'], contains('ended'));
        expect((await read(reference))['status'], 'unauthorized');
        expect(
          (await read(child, chat: 'synthetic-child'))['status'],
          'unauthorized',
        );
        final wrong = AgentConnectionProfile(
          address: address,
          deviceToken: profile.deviceToken,
          serverId: 'another-synthetic-server',
          certificate: profile.certificate,
        );
        final wrongFile = await wrong.saveIn(Directory('${root.path}/wrong'));
        expect(
          (await invoke(
            'info',
            [
              {'command': 'catalog'},
            ],
            args: ['--connection', wrongFile.path],
          )).single['status'],
          'server_changed',
        );
        final stored = await Directory(
          '${root.path}/state',
        ).list().where((f) => f is File).cast<File>().toList();
        for (final f in stored) {
          expect((await f.readAsString()).contains(ownerToken), isFalse);
        }
      } finally {
        owner.close();
        await server.close();
        await runtime.close();
        await repo.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
