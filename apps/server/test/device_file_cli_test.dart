import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:info_cli/codex_association.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'one-command CLI processes share a real device copy; guardian cleans after release, root end, crash and expiry without App',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-cli-file-');
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      late EncryptedInformationRepository repo;
      late OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient owner;
      var offset = Duration.zero;
      Future<void> open([int port = 0]) async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => DateTime.now().toUtc().add(offset),
        );
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'synthetic-cli-file-server',
          port: port,
        );
        owner = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
      }

      Future<void> close() async {
        owner.close();
        await server.close();
        await runtime.close();
        await repo.close();
      }

      await open();
      final associations = Directory('${root.path}/associations');
      final state = Directory('${associations.path}/device-files');
      final paths = <String>[];
      addTearDown(() async {
        // Even a failed assertion must not leave a synthetic guardian or copy.
        if (await state.exists()) {
          await for (final entity in state.list()) {
            if (entity is! File || !entity.path.endsWith('.json')) continue;
            final record = jsonDecode(await entity.readAsString()) as Map;
            final worker = record['workerPid'] as int;
            if (CredentialProcessIdentity.isActive(
                  worker,
                  record['workerIdentity'] as String,
                ) ==
                true) {
              Process.killPid(worker, ProcessSignal.sigterm);
              final wait = Stopwatch()..start();
              while (wait.elapsed < const Duration(seconds: 3) &&
                  CredentialProcessIdentity.isActive(
                        worker,
                        record['workerIdentity'] as String,
                      ) ==
                      true) {
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
            }
            if (record['lease'] is Map) {
              await NativeInformationDeliveryFiles().cleanup(
                InformationDeliveryLease.fromPrivateJson(
                  Map<String, dynamic>.from(record['lease'] as Map),
                ),
              );
            }
          }
        }
        await close();
        await root.delete(recursive: true);
      });
      final device = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'enroll',
        'name': 'Synthetic CLI',
      });
      final profile = AgentConnectionProfile(
        address: owner.address,
        deviceToken: device['deviceToken'] as String,
        serverId: owner.serverId,
        certificate: await File(fixture.ca).readAsString(),
      );
      final agent = AgentConnection(profile);
      addTearDown(agent.close);
      final opened = await agent.call('/session/lifecycle', {
        'chatLabel': 'Synthetic file chat',
      });
      var session = opened['sessionSecret'] as String;
      var end = opened['endCapability'] as String;
      var association = await CodexAssociation(
        'synthetic-cli-file-chat',
        server.port,
        session,
        connection: profile,
      ).save(associations);
      final script = File.fromUri(
        (await Isolate.resolvePackageUri(
          Uri.parse('package:info_cli/agent_client.dart'),
        ))!,
      ).parent.parent.uri.resolve('bin/codex_info.dart').toFilePath();
      Future<Map<String, dynamic>> cli(Map<String, dynamic> command) async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['--packages=${(await Isolate.packageConfig)!.toFilePath()}', script],
          environment: {'CODEX_THREAD_ID': 'synthetic-cli-file-chat'},
          runInShell: false,
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final error = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln(
          jsonEncode({'association': association, ...command}),
        );
        await process.stdin.close();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 50),
        );
        expect(code, 0, reason: await error);
        final result =
            jsonDecode((await output).trim()) as Map<String, dynamic>;
        for (final secret in [session, token, profile.deviceToken]) {
          expect(jsonEncode(result), isNot(contains(secret)));
        }
        return result;
      }

      final bytes = utf8.encode('SYNTHETIC_CLI_FILE_ORIGINAL\n原文内容');
      final upload = fileCandidateFromJson(
        (await owner.request('POST', '/v1/owner/files/uploads', {
          'operationId': 'upload',
          'originalName': 'sample.txt',
          'mediaType': 'text/plain',
          'bytes': base64Encode(bytes),
        }))['candidate'],
      );
      await owner.request(
        'POST',
        '/v1/owner/files/import',
        fileImportToJson(
          WorkspaceFileImport(
            operationId: 'save',
            selectionId: upload.selectionId,
            name: 'Synthetic CLI original',
          ),
        ),
      );
      final item = (await owner.information()).single;
      Future<String> request(String op) async {
        final result = await cli({
          'command': 'request',
          'operationId': op,
          'purpose': 'Synthetic file test',
          'fields': [FieldRef(item.id, item.fields.single.id).toJson()],
        });
        expect(result['status'], 'pending', reason: jsonEncode(result));
        final id = result['requestId'] as String;
        final detail = approvalDetailFromJson(
          await owner.request('GET', '/v1/owner/approvals/$id'),
        );
        await owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'approve-$op',
              requestId: id,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: [detail.scopes.single.id],
              fileVersions: {
                detail.scopes.single.id:
                    detail.scopes.single.fileVersions.single.ref.version,
              },
              fieldMinutes: 5,
            ),
          ),
        );
        return id;
      }

      var requestId = await request('request');
      Map<String, dynamic> fetch(String operation) => {
        'command': 'file-fetch',
        'requestId': requestId,
        'operationId': operation,
        'itemId': item.id,
        'fieldId': item.fields.single.id,
      };
      Future<(String, String)> received(String operation) async {
        final result = await cli(fetch(operation));
        expect(result['status'], 'ok', reason: jsonEncode(result));
        final delivery = result['delivery'] as Map;
        expect(delivery, isNot(contains('cleanupCapability')));
        final path = delivery['path'] as String;
        paths.add(path);
        expect(await File(path).readAsBytes(), bytes);
        expect(delivery['state'], 'ready');
        return (delivery['deliveryId'] as String, path);
      }

      Future<void> removed(String path) async {
        final wait = Stopwatch()..start();
        while (await File(path).exists() &&
            wait.elapsed < const Duration(seconds: 15)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await File(path).exists(), false);
      }

      final unconfigured = AgentClient.remote(profile, sessionSecret: session);
      try {
        expect(
          (await unconfigured.execute(fetch('unconfigured')))['errorCode'],
          'unsupported_capability',
        );
        expect(runtime.service.owner.informationFileDeliveries, isEmpty);
      } finally {
        unconfigured.close();
      }

      final first = await received('first');
      // A new CLI process returns the same physical copy, not a second download.
      expect(await received('first'), first);
      final concurrent = await Future.wait([
        received('concurrent'),
        received('concurrent'),
      ]);
      expect(concurrent[0], concurrent[1]);
      expect(
        (await cli({
          'command': 'file-release',
          'deliveryId': concurrent[0].$1,
        }))['status'],
        'ok',
      );
      await removed(concurrent[0].$2);
      final sameClient = AgentClient.remote(
        profile,
        sessionSecret: session,
        deviceFileStateDirectory: state,
      );
      try {
        final results = await Future.wait([
          sameClient.execute(fetch('same-client')),
          sameClient.execute(fetch('same-client')),
        ]);
        expect(results.every((r) => r['status'] == 'ok'), true);
        expect(
          (results[0]['delivery'] as Map)['path'],
          (results[1]['delivery'] as Map)['path'],
        );
        final copyPath = (results[0]['delivery'] as Map)['path'] as String;
        paths.add(copyPath);
        await cli({
          'command': 'file-release',
          'deliveryId': (results[0]['delivery'] as Map)['deliveryId'],
        });
        await removed(copyPath);
      } finally {
        sameClient.close();
      }
      final port = server.port;
      await close();
      await open(port);
      expect(await received('first'), first);
      final release = await cli({
        'command': 'file-release',
        'deliveryId': first.$1,
      });
      expect(release['status'], 'ok', reason: jsonEncode(release));
      await removed(first.$2);
      final ended = await received('ended');
      final localRecords = await state
          .list()
          .where((e) => e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      for (final record in localRecords) {
        final text = await record.readAsString();
        expect(text, isNot(contains(session)));
        expect(text, isNot(contains('sessionSecret')));
        expect(text, isNot(contains(utf8.decode(bytes))));
        expect((await record.stat()).mode & 0xE3F, 0);
      }
      expect(
        (await agent.call('/session/end', {'endCapability': end}))['status'],
        'ended',
      );
      await removed(ended.$2);
      expect((await cli(fetch('ended')))['status'], 'unauthorized');
      final another = await agent.call('/session/lifecycle', {
        'chatLabel': 'Synthetic next chat',
      });
      session = another['sessionSecret'] as String;
      end = another['endCapability'] as String;
      association = await CodexAssociation(
        'synthetic-cli-file-chat',
        server.port,
        session,
        connection: profile,
      ).save(associations);
      requestId = await request('second-request');
      final crashed = await received('crash');
      final recordFile =
          (await state
                  .list()
                  .where((e) => e.path.endsWith('.json'))
                  .cast<File>()
                  .toList())
              .firstWhere(
                (f) =>
                    (jsonDecode(f.readAsStringSync())['manifest']
                        as Map)['deliveryId'] ==
                    crashed.$1,
              );
      final record = jsonDecode(await recordFile.readAsString()) as Map;
      final worker = record['workerPid'] as int;
      expect(
        CredentialProcessIdentity.isActive(
          worker,
          record['workerIdentity'] as String,
        ),
        true,
      );
      expect(Process.killPid(worker, ProcessSignal.sigkill), true);
      final dead = Stopwatch()..start();
      while (CredentialProcessIdentity.isActive(
                worker,
                record['workerIdentity'] as String,
              ) !=
              false &&
          dead.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        (await agent.call('/session/end', {'endCapability': end}))['status'],
        'ended',
      );
      await recordFile.writeAsString(
        jsonEncode({
          ...record,
          'lease': {
            ...record['lease'] as Map,
            'fileIdentity': 'wrong-file-identity',
          },
        }),
        flush: true,
      );
      expect((await cli({'command': 'catalog'}))['status'], 'ok');
      expect(await File(crashed.$2).exists(), true);
      await recordFile.writeAsString(jsonEncode(record), flush: true);
      // Even after the chat ends, an ordinary command can finish cleanup using
      // the private cleanup-only journal, without recovering its read proof.
      expect((await cli({'command': 'catalog'}))['status'], 'ok');
      expect((await cli(fetch('crash')))['status'], 'unauthorized');
      await removed(crashed.$2);
      final third = await agent.call('/session/lifecycle', {
        'chatLabel': 'Synthetic final chat',
      });
      session = third['sessionSecret'] as String;
      end = third['endCapability'] as String;
      association = await CodexAssociation(
        'synthetic-cli-file-chat',
        server.port,
        session,
        connection: profile,
      ).save(associations);
      requestId = await request('third-request');
      final modified = await received('modified');
      await File(
        modified.$2,
      ).writeAsString('TAMPERED_SYNTHETIC_BYTES', flush: true);
      final refused = await cli(fetch('modified'));
      expect(refused['status'], 'failed');
      expect(refused, isNot(contains('delivery')));
      await removed(modified.$2);
      final revoked = await received('revoked');
      final revokeDetail = approvalDetailFromJson(
        await owner.request('GET', '/v1/owner/approvals/$requestId'),
      );
      await owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'revoke',
            requestId: requestId,
            reviewToken: revokeDetail.reviewToken,
            action: WorkspaceApprovalAction.revoke,
          ),
        ),
      );
      await removed(revoked.$2);
      expect((await cli(fetch('revoked')))['status'], 'unauthorized');
      requestId = await request('fourth-request');
      final expiring = await received('expires');
      offset = const Duration(minutes: 6);
      await removed(expiring.$2);
      final wait = Stopwatch()..start();
      while (runtime.service.owner.informationFileDeliveries.any(
            (r) => r.holdsCopy,
          ) &&
          wait.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        runtime.service.owner.informationFileDeliveries.every(
          (r) => !r.holdsCopy,
        ),
        true,
      );
      for (final path in paths) {
        expect(await File(path).exists(), false);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
