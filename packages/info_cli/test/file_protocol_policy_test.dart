import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

const synthetic =
    '[default]\naws_access_key_id=TEST_ONLY\naws_secret_access_key=SYNTHETIC_ONLY\n';
void main() {
  test(
    'public file requests reject unknown, mistyped and concatenated references and case-conflicting environment names without creating a request',
    () async {
      final h = await RuntimeHarness.create(fileBytes: utf8.encode(synthetic));
      addTearDown(h.close);
      for (final scenario in <(Map<String, Object?>, String)>[
        (
          {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'unknown'},
          },
          'invalid_reference',
        ),
        (
          {
            'AWS_SHARED_CREDENTIALS_FILE': {'secret': 'token'},
          },
          'invalid_reference',
        ),
        (
          {'AWS_SHARED_CREDENTIALS_FILE': 'prefix/{{file:token}}'},
          'invalid_reference',
        ),
        (
          {
            'AWS_SHARED_CREDENTIALS_FILE': {
              'file': 'token',
              'suffix': '/extra',
            },
          },
          'invalid_type',
        ),
        (
          {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
            'aws_shared_credentials_file': {'file': 'token'},
          },
          'invalid_env',
        ),
      ]) {
        final response = await h.client.execute({
          'protocolVersion': 1,
          'command': 'request-use',
          'purpose': 'Synthetic policy check',
          'credentials': [
            {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'aws_shared_credentials',
            'executable': h.executablePath,
            'argv': ['sts', 'get-caller-identity', '--region', 'us-east-1'],
            'cwd': Directory.current.path,
            'env': scenario.$1,
          },
        });
        expect(response['errorCode'], scenario.$2);
        expect(response['attemptConsumed'], isNot(true));
      }
      expect(h.service.owner.credentialUseRequests, isEmpty);
      expect(h.service.owner.credentialExecutions, isEmpty);
    },
  );
  test(
    'cleanup refuses a hard-linked registered material and preserves its outside link until separately removed',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'file-hardlink-fixture-',
      );
      final link = File('${outside.path}/outside-link');
      final h = await RuntimeHarness.create(fileBytes: utf8.encode(synthetic));
      CredentialExecutionMaterial? material;
      addTearDown(() async {
        if (await link.exists()) await link.delete();
        if (material != null &&
            h.service.owner.credentialExecutions.single.state == 'preparing') {
          await h.service.agent.reportCredentialExecution(
            CredentialExecutionReport(
              executionId: material.executionId,
              executionCapability: material.executionCapability,
              state: 'prepare_failed',
              errorCode: 'material_prepare_failed',
              finishedAt: DateTime.now().toUtc(),
            ),
          );
        }
        await h.close();
        await outside.delete();
      });
      final request = await h.approve(
        argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
      );
      material = await h.service.agent.consumeCredentialUse(
        h.client.sessionSecret!,
        request,
      );
      final lease = ManagedCredentialFiles.reserve(material.materialLease!, [
        'credential.bin',
        'aws-config',
      ]);
      await h.service.agent.registerCredentialMaterials(
        material.executionId,
        material.executionCapability,
        lease,
      );
      ManagedCredentialFiles.write(
        lease,
        'credential.bin',
        material.credentialMaterial.bytes,
      );
      ManagedCredentialFiles.write(lease, 'aws-config', const []);
      final original = File('${lease.path}/credential.bin');
      final system = Platform.environment['SystemRoot']!;
      final ps = await Process.start(
        '$system/System32/WindowsPowerShell/v1.0/powershell.exe',
        const [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''$ErrorActionPreference='Stop';[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);$v=[Console]::In.ReadToEnd()|ConvertFrom-Json;New-Item -ItemType HardLink -Path $v.link -Target $v.original|Out-Null''',
        ],
        environment: {'SystemRoot': system, 'WINDIR': system},
        includeParentEnvironment: false,
        runInShell: false,
      );
      final stdout = ps.stdout.drain<void>(), stderr = ps.stderr.drain<void>();
      ps.stdin.write(
        jsonEncode({'link': link.path, 'original': original.path}),
      );
      await ps.stdin.close();
      expect(await ps.exitCode, 0);
      await Future.wait([stdout, stderr]);
      await h.service.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: material.executionId,
          executionCapability: material.executionCapability,
          state: 'prepare_failed',
          errorCode: 'material_prepare_failed',
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      await expectLater(
        h.service.owner.cleanupCredentialExecution(material.executionId),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'cleanup_identity_mismatch',
          ),
        ),
      );
      expect(
        h.service.owner.credentialExecutions.single.cleanupState,
        'needs_check',
      );
      expect(await original.readAsString(), synthetic);
      expect(await link.readAsString(), synthetic);
      await link.delete();
      expect(
        (await h.service.owner.cleanupCredentialExecution(
          material.executionId,
        )).cleanupState,
        'complete',
      );
      expect(
        h.service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
    },
    skip: !Platform.isWindows,
  );
}
