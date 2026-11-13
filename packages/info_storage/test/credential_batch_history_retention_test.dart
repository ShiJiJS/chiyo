import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import '../../info_core/test_support/operation_history.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  for (final program in [false, true]) {
    test(
      'SQLCipher ${program ? 'program' : 'fill'} IDs survive online restart; retention is atomic',
      () async {
        final root = await Directory.systemTemp.createTemp('batch-retention-');
        final keys = TestKeyStore();
        var now = DateTime.utc(2026, 11, 1);
        var repo = await EncryptedInformationRepository.openOnline(
          root.path,
          keys,
        );
        var runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => now,
        );
        addTearDown(() async {
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        });
        final f = OperationHistoryFixture(runtime.service, repo, now);
        await runtime.run(() => f.open(program: program, count: 2));
        now = now.add(const Duration(days: 100));
        await runtime.run(runtime.service.owner.pruneCredentialUseHistory);
        expect(repo.credentialBatches, hasLength(1));
        await runtime.close();
        await repo.close();
        repo = await EncryptedInformationRepository.openOnline(root.path, keys);
        runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => now,
        );
        await runtime.run(runtime.service.owner.pruneCredentialUseHistory);
        expect(repo.credentialBatches, hasLength(1));
        final original = await runtime.run(
          () => runtime.service.agent.requestCredentialBatch(
            f.session,
            f.request.deviceId,
            f.input,
            operationId: f.request.operationId,
          ),
        );
        expect(original.id, f.request.id);
        await expectLater(
          runtime.run(
            () => runtime.service.agent.requestCredentialBatch(
              f.session,
              f.request.deviceId,
              f.input,
              operationId: 'op-000000',
            ),
          ),
          throwsA(
            isA<CredentialUseFailure>().having(
              (e) => e.code,
              'code',
              'operation_conflict',
            ),
          ),
        );

        final plan = CredentialBatchHistoryPrune(
          requests: repo.credentialBatches,
          operations: repo.credentialBatchOperations,
          programs: repo.credentialProgramOperations,
        );
        var checks = 0;
        await expectLater(
          repo.pruneCredentialBatchHistory(
            plan,
            validate: () {
              if (++checks == 2)
                throw StateError('synthetic final validation failure');
            },
          ),
          throwsStateError,
        );
        expect(checks, 2);
        expect(repo.credentialBatches, hasLength(1));
        expect(
          program
              ? repo.credentialProgramOperations.length
              : repo.credentialBatchOperations.length,
          2,
        );
        // Reopening proves the transaction rolled back on disk, not just in a cache.
        await runtime.close();
        await repo.close();
        repo = await EncryptedInformationRepository.openOnline(root.path, keys);
        runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => now,
        );
        expect(repo.credentialBatches, hasLength(1));
        expect(
          program
              ? repo.credentialProgramOperations.length
              : repo.credentialBatchOperations.length,
          2,
        );
        await runtime.run(() => runtime.service.agent.endSession(f.session));
        final preview = await runtime.run(
          () => runtime.service.owner.previewAuditRetention(30),
        );
        expect(preview.credentialRequests, 1);
        expect(preview.credentialExecutions, 2);
        await runtime.run(runtime.service.owner.pruneCredentialUseHistory);
        expect(repo.credentialBatches, isEmpty);
        expect(repo.credentialBatchOperations, isEmpty);
        expect(repo.credentialProgramOperations, isEmpty);
        await runtime.close();
        await repo.close();
        repo = await EncryptedInformationRepository.openOnline(root.path, keys);
        runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => now,
        );
        expect(repo.credentialBatches, isEmpty);
        expect(
          () => runtime.service.agent.showOwnOperation(f.session, 'op-000000'),
          throwsA(isA<AccessFailure>()),
        );
      },
    );
  }
}
