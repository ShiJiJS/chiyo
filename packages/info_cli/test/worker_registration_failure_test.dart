import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

class _FailingWorkerRegistry extends MemoryInformationRepository {
  var rejected = 0;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (executions.any((e) => e.workerPid != null) && rejected == 0) {
      rejected++;
      throw StateError('Synthetic worker registry unavailable');
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
    'a durable worker registration failure stops the waiting worker before target creation and consumes only the original attempt',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'worker-registration-failure-',
      );
      final marker = File('${root.path}/target-started');
      await File('${root.path}/api').writeAsString(
        "import 'dart:io'; Future<void> main() => File('target-started').writeAsString('started');",
      );
      final repository = _FailingWorkerRegistry(),
          h = await RuntimeHarness.create(repository: repository);
      addTearDown(() async {
        await h.close();
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            )) {
          throw StateError('Unexpected registration fixture');
        }
        await root.delete(recursive: true);
      });
      final request = await h.approve(cwd: root.path);
      final accepted = await h.client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      await h.client.drainCredentialExecutions();
      expect(repository.rejected, 1);
      expect(await marker.exists(), isFalse);
      final record = h.service.owner.credentialExecutions.single;
      expect(record.state, 'start_failed');
      expect(record.processStarted, isFalse);
      expect(record.exitCode, isNull);
      expect(
        h.service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
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
