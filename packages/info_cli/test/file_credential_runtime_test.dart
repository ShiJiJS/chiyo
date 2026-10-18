import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'approved AWS file use privately prepares exact material, runs a real receiver and cleans files after exit',
    () async {
      late String materialPath, configPath;
      final h = await RuntimeHarness.create(
        fileBytes: utf8.encode(
          '[default]\naws_access_key_id = TEST_ACCESS_ONLY\naws_secret_access_key = SYNTHETIC_NOT_A_REAL_SECRET\n',
        ),
        starter: (exe, argv, cwd, env) async {
          materialPath = env['AWS_SHARED_CREDENTIALS_FILE']!;
          configPath = env['AWS_CONFIG_FILE']!;
          return Process.start(
            exe,
            [
              File('test/support/credential_file_child.dart').absolute.path,
              ...argv,
            ],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      addTearDown(h.close);
      final request = await h.approve(
        argv: [
          'ssm',
          'put-parameter',
          '--name',
          '/test/value',
          '--value',
          '{{file:token}}',
          '--region',
          'us-east-1',
        ],
      );
      final accepted = await h.client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      await h.client.drainCredentialExecutions();
      final status = await h.client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(
        status['executionState'],
        'exited',
        reason: 'Execution result code: ${status['errorCode']}',
      );
      expect(status['exitCode'], 0);
      expect(status['cleanupState'], 'complete');
      final output = await h.client.execute({
        'command': 'execution-output',
        'executionId': accepted['executionId'],
      });
      final raw = (output['chunks'] as List)
          .where((c) => c['stream'] == 'stdout')
          .expand<int>((c) => base64Decode(c['dataBase64'] as String))
          .toList();
      expect(jsonDecode(utf8.decode(raw)), {
        'materialMatches': true,
        'configEmpty': true,
        'privateAcl': true,
        'literalPreserved': true,
        'otherAuthAbsent': true,
      });
      expect(await File(materialPath).exists(), isFalse);
      expect(await File(configPath).exists(), isFalse);
      expect(await File(materialPath).parent.exists(), isFalse);
      expect(jsonEncode(status), isNot(contains(materialPath)));
      expect(
        (await h.client.execute({
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
}
