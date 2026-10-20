import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'file_credential_use_test.dart' show fileSession, awsInput;

void main() {
  test(
    'a launch interrupted before its worker registers can be reconciled only after its original supervisor ends',
    () async {
      final (service, session, credential) = await fileSession();
      final root = await Directory.systemTemp.createTemp(
        'supervisor-recovery-',
      );
      final release = File('${root.path}/release');
      final script = File('${root.path}/wait.dart');
      await script.writeAsString(
        "import 'dart:io'; Future<void> main() async { final end=DateTime.now().add(const Duration(seconds:20)); while(!await File('release').exists() && DateTime.now().isBefore(end)){await Future<void>.delayed(const Duration(milliseconds:20));}}",
      );
      final supervisor = await Process.start(Platform.resolvedExecutable, [
        script.path,
      ], workingDirectory: root.path);
      final stdoutDone = supervisor.stdout.drain<void>(),
          stderrDone = supervisor.stderr.drain<void>();
      final identity = CredentialProcessIdentity.capture(supervisor.pid)!;
      addTearDown(() async {
        await release.writeAsString('release');
        await supervisor.exitCode;
        await stdoutDone;
        await stderrDone;
        identity.close();
        await service.owner.reconcileCredentialMaterialCleanup();
        await service.close();
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (!actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            ) ||
            actual.toLowerCase() != root.absolute.path.toLowerCase()) {
          throw StateError('Unexpected recovery fixture');
        }
        await root.delete(recursive: true);
      });
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
        supervisorPid: supervisor.pid,
        supervisorCreatedAt: identity.value,
      );
      final record = service.owner.credentialExecutions.single;
      expect(CredentialProcessJob.validName(record.jobName!), isTrue);
      expect(jsonEncode(record.toJson()), isNot(contains('supervisor')));
      expect(jsonEncode(record.toJson()), isNot(contains(record.jobName!)));
      await service.owner.reconcileCredentialMaterialCleanup();
      expect(service.owner.credentialExecutions.single.state, 'preparing');
      expect(await Directory(material.materialLease!.path).exists(), isTrue);
      await release.writeAsString('release');
      await supervisor.exitCode;
      await service.owner.reconcileCredentialMaterialCleanup();
      final recovered = service.owner.credentialExecutions.single;
      expect(recovered.state, 'unknown');
      expect(recovered.processStarted, isFalse);
      expect(recovered.exitCode, isNull);
      expect(recovered.cleanupState, 'complete');
      expect(await Directory(material.materialLease!.path).exists(), isFalse);
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
    skip: !Platform.isWindows && !Platform.isMacOS,
  );
}
