import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

class RegistrationAuditFailure extends MemoryInformationRepository {
  bool failed = false, emptyAtFailure = false;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    final lease = executions
        .map((e) => e.materialLease)
        .whereType<CredentialMaterialLease>()
        .where((l) => l.files.isNotEmpty)
        .firstOrNull;
    if (!failed && lease != null) {
      failed = true;
      emptyAtFailure = lease.files.keys.every(
        (name) =>
            File('${lease.path}${Platform.pathSeparator}$name').lengthSync() ==
            0,
      );
      throw StateError('Controlled registration audit failure');
    }
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
  }
}

void main() {
  test(
    'cleanup refuses an identity-replaced file and never deletes the preserved source material',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'runtime-replacement-',
      );
      final source = File('${fixture.path}/preserved-original');
      String? path;
      late RuntimeHarness h;
      h = await RuntimeHarness.create(
        fileBytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_NOT_A_REAL_SECRET\n',
        ),
        starter: (exe, argv, cwd, env) async {
          path = env['AWS_SHARED_CREDENTIALS_FILE']!;
          await File(path!).rename(source.path);
          await File(path!).writeAsString('foreign-file-must-survive');
          final system = env['SystemRoot']!;
          final acl = await Process.start(
            '$system/System32/WindowsPowerShell/v1.0/powershell.exe',
            const [
              '-NoLogo',
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'''[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);$inputData=[Console]::In.ReadToEnd()|ConvertFrom-Json;$acl=Get-Acl -LiteralPath $inputData.source;Set-Acl -LiteralPath $inputData.destination -AclObject $acl''',
            ],
            environment: {'SystemRoot': system, 'WINDIR': system},
            includeParentEnvironment: false,
            runInShell: false,
          );
          final output = acl.stdout.drain<void>(),
              errors = acl.stderr.drain<void>();
          acl.stdin.write(
            jsonEncode({'source': source.path, 'destination': path}),
          );
          await acl.stdin.close();
          expect(await acl.exitCode, 0);
          await Future.wait([output, errors]);
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
      addTearDown(() async {
        if (path != null && await source.exists()) {
          if (await File(path!).exists()) await File(path!).delete();
          await source.rename(path!);
        }
        await h.close();
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
      final status = await h.client.execute({
        'command': 'execution-status',
        'executionId': run['executionId'],
      });
      expect(status['executionState'], 'exited');
      expect(status['exitCode'], 7);
      expect(status['cleanupState'], 'needs_check');
      expect(await File(path!).readAsString(), 'foreign-file-must-survive');
      expect(
        await source.readAsString(),
        contains('SYNTHETIC_NOT_A_REAL_SECRET'),
      );
      expect(
        (await h.client.execute({
          'command': 'cleanup-use',
          'executionId': run['executionId'],
        }))['errorCode'],
        'cleanup_identity_mismatch',
      );
      expect(await File(path!).readAsString(), 'foreign-file-must-survive');
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
    'resource audit failure writes no credential bytes, starts no program and records a consumed preparation failure',
    () async {
      final repository = RegistrationAuditFailure();
      var started = false;
      final h = await RuntimeHarness.create(
        repository: repository,
        fileBytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_NOT_A_REAL_SECRET\n',
        ),
        starter: (exe, argv, cwd, env) async {
          started = true;
          throw StateError('No program may start after failed resource audit');
        },
      );
      addTearDown(h.close);
      final request = await h.approve(
        argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
      );
      final run = await h.client.execute({
        'protocolVersion': 1,
        'command': 'run-use',
        'requestId': request,
      });
      expect(run['status'], 'accepted');
      await h.client.drainCredentialExecutions();
      final status = await h.client.execute({
        'command': 'execution-status',
        'executionId': run['executionId'],
      });
      expect(status['executionState'], 'prepare_failed');
      expect(status['errorCode'], 'audit_unavailable');
      expect(status['processStarted'], isFalse);
      expect(status['attemptConsumed'], isTrue);
      expect(status['cleanupState'], 'complete');
      expect(repository.emptyAtFailure, isTrue);
      expect(started, isFalse);
      expect(
        await Directory(
          h.service.owner.credentialExecutions.single.materialLease!.path,
        ).exists(),
        isFalse,
      );
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
