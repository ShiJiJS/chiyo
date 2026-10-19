import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows UI approves fixed SSH file plans for the compiled CLI and real OpenSSH, with encrypted receipts reopened',
    (tester) async {
      const cliPath = String.fromEnvironment('CLI_EXECUTABLE');
      const ssh = String.fromEnvironment('SSH_EXECUTABLE');
      const keys = String.fromEnvironment('SSH_FIXTURE');
      const port = String.fromEnvironment('SSH_FIXTURE_PORT');
      expect(cliPath, isNotEmpty);
      expect(ssh, isNotEmpty);
      expect(keys, isNotEmpty);
      expect(port, isNotEmpty);
      final fixture = await IsolatedDesktopFixture.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      });
      final service = fixture.service;
      final cli = await Process.start(cliPath, [
        '--port',
        '${fixture.port}',
      ], workingDirectory: fixture.root.path);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        await cli.stdin.close();
        await cli.exitCode.timeout(const Duration(seconds: 15));
        await lines.cancel();
        await errors;
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        cli.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      await command({'command': 'session', 'chatLabel': '验证 SSH 文件使用'});
      final host = (await File(
        '$keys/host.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      final changed = (await File(
        '$keys/wrong-client.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      final exits = <int>[];
      for (final scenario in [
        ('匹配主机与私钥', 'client', '[127.0.0.1]:$port $host', 0),
        ('错误私钥', 'wrong-client', '[127.0.0.1]:$port $host', 255),
        ('未知主机', 'client', '[unknown.invalid]:$port $host', 255),
        ('主机密钥已变化', 'client', '[127.0.0.1]:$port $changed', 255),
      ]) {
        await service.owner.configureSshKnownHosts(
          '合成主机 · ${scenario.$1}',
          utf8.encode('${scenario.$3}\n'),
        );
        var credential = await service.owner.createFileCredential(
          name: '合成私钥 · ${scenario.$1}',
          publicPurpose: '隔离验收，不含真实账号',
          fileName: 'synthetic_ed25519',
          bytes: await File('$keys/${scenario.$2}').readAsBytes(),
        );
        credential = await service.owner.updateCredentialMetadata(
          credential.id,
          credential.revision,
          name: credential.name,
          publicPurpose: credential.publicPurpose,
          privateNote: '',
          suggestedBinding: 'SSH_KEY_FILE',
          discoverable: true,
        );
        final item = service.owner.information.single;
        final field = FieldRef(item.id, item.fields.first.id);
        final request = await command({
          'protocolVersion': 1,
          'command': 'request-use',
          'purpose': '${scenario.$1}：只连接本轮localhost测试服务，执行固定非交互命令。',
          'credentials': [
            {'alias': 'ssh_key', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'ssh_identity',
            'executable': ssh,
            'cwd': fixture.root.path,
            'argv': [
              '-T',
              '-o',
              'BatchMode=yes',
              '-i',
              {'file': 'ssh_key'},
              '-p',
              port,
              'fixture@127.0.0.1',
              '/usr/bin/true',
            ],
            'env': <String, Object?>{},
          },
          'readFields': [field.toJson()],
        });
        expect(request['status'], 'pending', reason: '${request['errorCode']}');
        final requestId = request['requestId'] as String;
        expect(
          (await command({
            'protocolVersion': 1,
            'command': 'run-use',
            'requestId': requestId,
          }))['errorCode'],
          'request_pending',
        );
        await tester.pumpWidget(
          InformationApp(
            key: UniqueKey(),
            service: service,
            port: fixture.port,
            runtime: fixture.bootstrap.runtime,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('ssh 的 -i 参数'), findsOneWidget);
        final approve = find.byKey(const ValueKey('credential-use-approve'));
        await tester.ensureVisible(approve);
        await tester.tap(approve);
        await tester.pumpAndSettle();
        expect(find.textContaining('StrictHostKeyChecking=yes'), findsWidgets);
        await tester.tap(find.text('确认批准'));
        await tester.pumpAndSettle();
        expect(
          service.owner.credentialUseRequests
              .firstWhere((r) => r.id == requestId)
              .credentialApproved,
          isTrue,
        );
        expect(
          (await command({
            'command': 'claim',
            'requestId': requestId,
          }))['status'],
          'ok',
        );
        expect(
          (await command({
            'command': 'read',
            'requestId': requestId,
            ...field.toJson(),
          }))['value'],
          'native.example.invalid',
        );
        final accepted = await command({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': requestId,
        });
        expect(accepted['status'], 'accepted');
        final executionId = accepted['executionId'] as String;
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        late Map<String, dynamic> status;
        do {
          status = await command({
            'command': 'execution-status',
            'executionId': executionId,
          });
          if (!{'preparing', 'running'}.contains(status['executionState']) &&
              status['cleanupState'] != 'pending') {
            break;
          }
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Synthetic SSH execution did not finish',
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
        } while (true);
        expect(
          status['executionState'],
          'exited',
          reason: '${status['errorCode']}',
        );
        if (status['exitCode'] != scenario.$4) {
          final output = await command({
            'command': 'execution-output',
            'executionId': executionId,
          });
          final diagnostic = utf8.decode([
            for (final dynamic c in output['chunks'] as List)
              ...base64Decode(c['dataBase64'] as String),
          ], allowMalformed: true);
          fail(
            'Synthetic SSH ${scenario.$1}: exit ${status['exitCode']}; $diagnostic',
          );
        }
        expect(status['processStarted'], isTrue);
        expect(status['exitCode'], scenario.$4);
        expect(status['cleanupState'], 'complete');
        expect(jsonEncode(status).contains('info-managed-'), isFalse);
        expect(
          (await command({
            'protocolVersion': 1,
            'command': 'run-use',
            'requestId': requestId,
          }))['errorCode'],
          'attempt_consumed',
        );
        exits.add(status['exitCode'] as int);
        final receipt = service.owner.credentialExecutions.firstWhere(
          (e) => e.id == executionId,
        );
        expect(await Directory(receipt.materialLease!.path).exists(), isFalse);
      }
      await cli.stdin.close();
      expect(await cli.exitCode, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.bootstrap.runtime!.stop();
      final repository = await EncryptedInformationRepository.open(
        fixture.root.path,
        WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
      );
      final reopened = InformationService(repository: repository);
      try {
        expect(
          reopened.owner.credentialExecutions.map((e) => e.exitCode).toList()
            ..sort(),
          [0, 255, 255, 255],
        );
        expect(
          reopened.owner.credentialExecutions.every(
            (e) => e.cleanupState == 'complete',
          ),
          isTrue,
        );
        expect(
          reopened.owner.credentialUseRequests.every((r) => r.attemptConsumed),
          isTrue,
        );
        expect(reopened.owner.sshKnownHosts, isNotNull);
      } finally {
        await reopened.close();
        await repository.close();
      }
      debugPrint(
        'D7_NATIVE_VERIFIED UI approval → compiled CLI/worker → real OpenSSH; exits $exits; four cleanups complete; independent field reads; SQLCipher/DPAPI reopen. Synthetic localhost keys only.',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
