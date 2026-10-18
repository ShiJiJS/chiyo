import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native UI approval and history use the shipped resident worker across independent adapters, then retain running SSH materials across runtime exit and reopen',
    (tester) async {
      const adapter = String.fromEnvironment('CODEX_EXECUTABLE'),
          worker = String.fromEnvironment('WORKER_EXECUTABLE');
      const ssh = String.fromEnvironment('SSH_EXECUTABLE'),
          keys = String.fromEnvironment('SSH_FIXTURE'),
          port = String.fromEnvironment('SSH_FIXTURE_PORT');
      for (final path in [adapter, worker, ssh, keys, port]) {
        expect(path, isNotEmpty);
      }
      final fixture = await IsolatedDesktopFixture.start(
        credentialWorkerExecutable: worker,
      );
      final service = fixture.service;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.close();
      });
      final bootstrapClient = AgentClient(fixture.port);
      await bootstrapClient.execute({
        'command': 'session',
        'chatLabel': '核对北辰测试服务器',
      });
      final reference = await CodexAssociation(
        'hosted-native-chat',
        fixture.port,
        bootstrapClient.sessionSecret!,
      ).save(Directory('${fixture.root.path}/associations'));
      bootstrapClient.close();
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        final process = await Process.start(
          adapter,
          [],
          environment: {'CODEX_THREAD_ID': 'hosted-native-chat'},
          workingDirectory: fixture.root.path,
        );
        final out = process.stdout.transform(utf8.decoder).join(),
            err = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln(jsonEncode({'association': reference, ...input}));
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await err, isEmpty);
        return jsonDecode(await out) as Map<String, dynamic>;
      }

      final host = (await File(
        '$keys/host.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      await service.owner.configureSshKnownHosts(
        '合成localhost主机',
        utf8.encode('[127.0.0.1]:$port $host\n'),
      );
      var credential = await service.owner.createFileCredential(
        name: '北辰测试 SSH 私钥',
        publicPurpose: '隔离原生验收',
        fileName: 'synthetic_ed25519',
        bytes: await File('$keys/client').readAsBytes(),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'ssh_key',
        discoverable: true,
      );
      final item = service.owner.information.single,
          field = FieldRef(
            service.owner.information.single.id,
            service.owner.information.single.fields.first.id,
          );
      expect(item.fields.first.value, 'native.example.invalid');
      Future<String> approve(String purpose, List<String> remote) async {
        final requested = await command({
          'command': 'request-use',
          'purpose': purpose,
          'credentials': [
            {'alias': 'ssh_key', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'ssh_identity',
            'executable': ssh,
            'argv': [
              '-T',
              '-o',
              'BatchMode=yes',
              '-i',
              {'file': 'ssh_key'},
              '-p',
              port,
              'fixture@127.0.0.1',
              ...remote,
            ],
            'cwd': fixture.root.path,
            'env': <String, Object?>{},
          },
          'readFields': [field.toJson()],
        });
        expect(requested['status'], 'pending');
        await tester.pumpWidget(
          InformationApp(
            key: UniqueKey(),
            service: service,
            port: fixture.port,
            runtime: fixture.bootstrap.runtime,
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('credential-use-approve'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认批准'));
        await tester.pumpAndSettle();
        final id = requested['requestId'] as String;
        expect(
          (await command({
            'command': 'read',
            'requestId': id,
            ...field.toJson(),
          }))['value'],
          'native.example.invalid',
        );
        return id;
      }

      final first = await approve('核对测试服务器输出', [
        '/usr/bin/printf',
        '%s',
        'hosted-native-ok',
      ]);
      final accepted = await command({
        'command': 'run-use',
        'requestId': first,
      });
      expect(accepted['status'], 'accepted');
      final executionId = accepted['executionId'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      Map<String, dynamic> status;
      do {
        status = await command({
          'command': 'execution-status',
          'executionId': executionId,
        });
        if (status['executionState'] == 'exited' &&
            status['cleanupState'] == 'complete') {
          break;
        }
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Hosted SSH did not finish',
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      } while (true);
      expect(status['exitCode'], 0);
      expect(status['outputAvailable'], isTrue);
      expect(jsonEncode(status), isNot(contains('supervisor')));
      expect(jsonEncode(status), isNot(contains('jobName')));
      final output = await command({
        'command': 'execution-output',
        'executionId': executionId,
        'cursor': 0,
        'limit': 16,
      });
      expect(
        utf8.decode([
          for (final dynamic chunk in output['chunks'] as List)
            ...base64Decode(chunk['dataBase64'] as String),
        ]),
        'hosted-native-ok',
      );
      expect(
        (await command({
          'command': 'run-use',
          'requestId': first,
        }))['errorCode'],
        'attempt_consumed',
      );
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('history-document-$first')), findsOneWidget);
      expect(find.text('已成功 · 退出码 0'), findsWidgets);
      expect(find.text('北辰测试 SSH 私钥'), findsOneWidget);

      final second = await approve('等待测试服务器任务结束', ['/bin/sleep', '6']);
      final running = await command({
        'command': 'run-use',
        'requestId': second,
      });
      expect(running['status'], 'accepted');
      final activeId = running['executionId'] as String;
      final startedBy = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        final current = service.owner.credentialExecutions.firstWhere(
          (e) => e.id == activeId,
        );
        if (current.state == 'running') break;
        expect(DateTime.now().isBefore(startedBy), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pumpWidget(const SizedBox());
      await fixture.bootstrap.runtime!.stop();
      final repository = await EncryptedInformationRepository.open(
        fixture.root.path,
        WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
      );
      final reopened = InformationService(repository: repository);
      try {
        final record = reopened.owner.credentialExecutions.firstWhere(
          (e) => e.id == activeId,
        );
        expect(record.state, 'unknown');
        expect(record.exitCode, isNull);
        expect(record.supervisorPid, isNotNull);
        expect(record.workerPid, isNotNull);
        expect(CredentialProcessJob.isActive(record.jobName!), isTrue);
        await reopened.owner.reconcileCredentialMaterialCleanup();
        expect(await Directory(record.materialLease!.path).exists(), isTrue);
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (CredentialProcessJob.isActive(record.jobName!) != false) {
          expect(DateTime.now().isBefore(end), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await reopened.owner.reconcileCredentialMaterialCleanup();
        final cleaned = reopened.owner.credentialExecutions.firstWhere(
          (e) => e.id == activeId,
        );
        expect(cleaned.state, 'unknown');
        expect(cleaned.exitCode, isNull);
        expect(cleaned.cleanupState, 'complete');
        expect(await Directory(record.materialLease!.path).exists(), isFalse);
        expect(
          reopened.owner.credentialUseRequests.every((r) => r.attemptConsumed),
          isTrue,
        );
      } finally {
        await reopened.close();
        await repository.close();
      }
      debugPrint(
        'D8_NATIVE_VERIFIED native UI approval/history; separate AOT adapters; shipped worker; real localhost OpenSSH output; no replay; runtime stop/SQLCipher-DPAPI reopen retains active job materials then cleans without inventing exit status. Synthetic only; no Codex model/config.',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
