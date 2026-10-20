import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart' as app;
import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows UI approves one synthetic Token launch through real CLI and gh without authenticating another account',
    (tester) async {
      const dart = String.fromEnvironment('DART_EXECUTABLE');
      const cliDirectory = String.fromEnvironment('CLI_DIRECTORY');
      const gh = String.fromEnvironment('GH_EXECUTABLE');
      const compiledCli = String.fromEnvironment('CLI_EXECUTABLE');
      expect(dart, isNotEmpty);
      expect(gh, isNotEmpty);
      final fixture = await IsolatedDesktopFixture.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.close();
      });
      final service = fixture.service;
      var credential = await service.owner.createStringCredential(
        name: '隔离验收 GitHub Token',
        publicPurpose: '验证非空合成 Token 被真实 gh 拒绝',
        secret: 'ghp_FICTIONAL_NATIVE_TOKEN_INVALID_20261017',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      await tester.pumpWidget(
        app.InformationApp(
          service: service,
          port: fixture.port,
          runtime: fixture.bootstrap.runtime,
        ),
      );
      await tester.pumpAndSettle();
      final cli = await Process.start(
        compiledCli.isEmpty ? dart : compiledCli,
        [
          if (compiledCli.isEmpty) ...['run', 'bin/info.dart'],
          '--port',
          '${fixture.port}',
        ],
        workingDirectory: cliDirectory,
      );
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await cli.stdin.close();
        await cli.exitCode.timeout(const Duration(seconds: 15));
        await lines.cancel();
        await errors;
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> data) async {
        cli.stdin.writeln(jsonEncode(data));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      await command({'command': 'session', 'chatLabel': '核对合成账号来源'});
      final item = service.owner.information.single;
      final field = FieldRef(item.id, item.fields.first.id);
      final request = await command({
        'protocolVersion': 1,
        'command': 'request-use',
        'purpose': '只用本次非空合成 Token 请求 GitHub /user，预期401，不读取用户已有账号。',
        'credentials': [
          {
            'alias': 'github_token',
            'credentialId': credential.id,
            'version': 1,
          },
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': gh,
          'argv': ['api', 'user', '--method', 'GET'],
          'cwd': fixture.root.path,
          'env': {
            'GH_TOKEN': {'secret': 'github_token'},
          },
        },
        'readFields': [field.toJson()],
      });
      expect(
        request['status'],
        'pending',
        reason:
            'errorCode=${request['errorCode']}; fieldPath=${request['fieldPath']}',
      );
      expect(
        await File('.local/state/gh/device-id').exists(),
        isFalse,
        reason:
            'Version inspection must not leave gh state in the caller working directory',
      );
      final id = request['requestId'] as String;
      expect(
        (await command({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': id,
        }))['errorCode'],
        'request_pending',
      );
      await tester.pumpAndSettle();
      final approve = find.byKey(const ValueKey('credential-use-approve'));
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(find.textContaining(gh), findsWidgets);
      await tester.tap(find.text('确认批准'));
      await tester.pumpAndSettle();
      expect(
        service.owner.credentialUseRequests.single.credentialApproved,
        isTrue,
      );
      final claimed = await command({'command': 'claim', 'requestId': id});
      expect(claimed['status'], 'ok');
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...field.toJson(),
        }))['value'],
        'native.example.invalid',
      );
      final accepted = await command({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': id,
      });
      expect(accepted['status'], 'accepted');
      final executionId = accepted['executionId'] as String;
      expect(
        (await command({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': id,
        }))['errorCode'],
        'attempt_consumed',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      late Map<String, dynamic> status;
      while (true) {
        status = await command({
          'command': 'execution-status',
          'executionId': executionId,
        });
        if (!{'preparing', 'running'}.contains(status['executionState'])) break;
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Synthetic gh did not finish',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(status['executionState'], 'exited');
      expect(status['processStarted'], isTrue);
      expect(status['exitCode'], 1);
      expect(status['cleanupState'], 'not_needed');
      final output = await command({
        'command': 'execution-output',
        'executionId': executionId,
      });
      final decoded = utf8.decode([
        for (final dynamic c in output['chunks'] as List)
          ...base64Decode(c['dataBase64'] as String),
      ]);
      expect(
        decoded.contains('401'),
        isTrue,
        reason: 'Only the synthetic unauthenticated negative path is accepted',
      );
      expect(decoded.contains('ghp_FICTIONAL_'), isFalse);
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...field.toJson(),
        }))['status'],
        'ok',
      );
      await cli.stdin.close();
      expect(await cli.exitCode, 0);
      await tester.pumpWidget(const SizedBox());
      await fixture.bootstrap.runtime!.stop();
      final reopened = await EncryptedInformationRepository.open(
        fixture.root.path,
        WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
      );
      final restored = InformationService(repository: reopened);
      try {
        expect(restored.owner.credentialExecutions.single.state, 'exited');
        expect(restored.owner.credentialExecutions.single.exitCode, 1);
        expect(
          restored.owner.credentialUseRequests.single.attemptConsumed,
          isTrue,
        );
        expect(
          jsonEncode(
            restored.owner.credentialExecutions.single.toStorageJson(),
          ).contains('ghp_FICTIONAL_'),
          isFalse,
        );
      } finally {
        await restored.close();
        await reopened.close();
      }
      debugPrint(
        'D6_NATIVE_VERIFIED UI → private consumption → CLI worker → real gh with nonempty synthetic Token → HTTP401/exit1; field grant independent; SQLCipher/DPAPI receipt reopened. No real account or keyring fallback queried.',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
