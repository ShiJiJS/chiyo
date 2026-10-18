import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'file_credential_use_test.dart' show fileSession, awsInput;

void main() {
  test(
    'unknown execution retains its files while the registered Windows job lives, then cleans without claiming command success',
    () async {
      final (service, session, credential) = await fileSession();
      final request = await service.agent.requestCredentialUse(
        session,
        awsInput(credential),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      final lease = ManagedCredentialFiles.reserve(material.materialLease!, [
        'credential.bin',
        'aws-config',
      ]);
      await service.agent.registerCredentialMaterials(
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
      final jobName =
          'Local\\AgentInfoRuntime-${material.executionId.substring(0, 32)}';
      final vm = '${File(Platform.resolvedExecutable).parent.path}/dartvm.exe';
      final child = await Process.start(vm, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/support/material_job_fixture.dart').absolute.path,
        jobName,
      ], includeParentEnvironment: true);
      final lines = StreamIterator(
        child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = child.stderr.drain<void>();
      var released = false;
      Future<void> release() async {
        if (released) return;
        released = true;
        await child.stdin.close();
        await lines.cancel();
        await child.exitCode.timeout(const Duration(seconds: 5));
        await errors;
      }

      addTearDown(() async {
        await release();
        ManagedCredentialFiles.cleanup(lease);
        await service.close();
      });
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      final ready = jsonDecode(lines.current) as Map<String, dynamic>;
      final started = DateTime.now().toUtc();
      await service.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: material.executionId,
          executionCapability: material.executionCapability,
          state: 'running',
          pid: ready['pid'] as int,
          processCreatedAt: ready['identity'] as String,
          jobName: jobName,
          startedAt: started,
        ),
      );
      await service.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: material.executionId,
          executionCapability: material.executionCapability,
          state: 'unknown',
          pid: ready['pid'] as int,
          processCreatedAt: ready['identity'] as String,
          jobName: jobName,
          startedAt: started,
          finishedAt: DateTime.now().toUtc(),
          errorCode: 'execution_unknown',
        ),
      );
      await expectLater(
        service.owner.cleanupCredentialExecution(material.executionId),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'cleanup_busy',
          ),
        ),
      );
      expect(await File('${lease.path}/credential.bin').exists(), isTrue);
      await release();
      final cleaned = await service.owner.cleanupCredentialExecution(
        material.executionId,
      );
      expect(cleaned.cleanupState, 'complete');
      expect(cleaned.state, 'unknown');
      expect(cleaned.exitCode, isNull);
      expect(await Directory(lease.path).exists(), isFalse);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'attempt_consumed',
          ),
        ),
      );
    },
    skip: !Platform.isWindows,
  );
}
