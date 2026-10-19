import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'a locked credential file reports cleanup failure independently from exit7, then retries cleanup without replay',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'runtime-lock-fixture-',
      );
      final releaseFile = File('${fixture.path}/release');
      Process? locker;
      StreamIterator<String>? lines;
      Future<void>? errors;
      late String materialPath;
      final h = await RuntimeHarness.create(
        fileBytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_NOT_A_REAL_SECRET\n',
        ),
        starter: (exe, argv, cwd, env) async {
          materialPath = env['AWS_SHARED_CREDENTIALS_FILE']!;
          final system = env['SystemRoot']!;
          locker = await Process.start(
            '$system/System32/WindowsPowerShell/v1.0/powershell.exe',
            const [
              '-NoLogo',
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'''$inputData=[Console]::In.ReadToEnd()|ConvertFrom-Json;$f=[IO.File]::Open($inputData.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);[Console]::Out.WriteLine('locked');[Console]::Out.Flush();$deadline=[DateTime]::UtcNow.AddSeconds(15);while(-not [IO.File]::Exists($inputData.release)){if([DateTime]::UtcNow -gt $deadline){break};Start-Sleep -Milliseconds 20};$f.Dispose()''',
            ],
            environment: {'SystemRoot': system, 'WINDIR': system},
            includeParentEnvironment: false,
            runInShell: false,
          );
          lines = StreamIterator(
            locker!.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          );
          errors = locker!.stderr.drain<void>();
          locker!.stdin.write(
            jsonEncode({'path': materialPath, 'release': releaseFile.path}),
          );
          await locker!.stdin.close();
          expect(
            await lines!.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          expect(lines!.current, 'locked');
          return Process.start(
            exe,
            [File('test/support/credential_exit_child.dart').absolute.path],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: false,
            runInShell: false,
          );
        },
      );
      Future<void> release() async {
        if (locker == null) return;
        try {
          await releaseFile.writeAsString('release');
          await lines!.cancel();
          await locker!.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          locker!.kill();
          await locker!.exitCode;
          rethrow;
        } finally {
          await lines!.cancel();
          await errors;
          locker = null;
        }
      }

      addTearDown(() async {
        await release();
        await h.close();
        if (await releaseFile.exists()) await releaseFile.delete();
        await fixture.delete();
      });
      final request = await h.approve(
        argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
      );
      final run = await h.client.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      await h.client.drainCredentialExecutions();
      Future<Map<String, dynamic>> status() => h.client.execute({
        'command': 'execution-status',
        'executionId': run['executionId'],
      });
      final failed = await status();
      expect(failed['executionState'], 'exited');
      expect(failed['exitCode'], 7);
      // Windows may reject deletion or refuse identity inspection while the
      // exclusive handle is held. Both must retain material, with an exact
      // matching typed error; neither changes the recorded process exit.
      expect(failed['cleanupState'], anyOf('failed', 'needs_check'));
      final blocked = await h.client.execute({
        'command': 'cleanup-use',
        'executionId': run['executionId'],
      });
      final stillBlocked = await status();
      expect(
        blocked['errorCode'],
        stillBlocked['cleanupState'] == 'failed'
            ? 'cleanup_failed'
            : 'cleanup_identity_mismatch',
      );
      expect(stillBlocked['cleanupState'], anyOf('failed', 'needs_check'));
      expect(stillBlocked['exitCode'], 7);
      expect(await File(materialPath).exists(), isTrue);
      await release();
      expect(
        (await h.client.execute({
          'command': 'cleanup-use',
          'executionId': run['executionId'],
        }))['cleanupState'],
        'complete',
      );
      expect((await status())['exitCode'], 7);
      expect(await File(materialPath).exists(), isFalse);
      expect(
        (await h.client.execute({
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
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
        'protocolVersion': 1,
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
          'protocolVersion': 1,
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
}
