import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import '../test_support/operation_history.dart';

void main() {
  for (final program in [false, true]) {
    test(
      '${program ? 'program' : 'fill'} history preserves live chat IDs and prunes the complete ended request',
      () async {
        var now = DateTime.utc(2026, 11, 1);
        final repo = MemoryInformationRepository();
        final service = InformationService(repository: repo, clock: () => now);
        addTearDown(service.close);
        final fixture = OperationHistoryFixture(service, repo, now);
        await fixture.open(program: program, count: 2);
        now = now.add(const Duration(days: 100));
        expect(
          (await service.owner.previewAuditRetention(30)).credentialRequests,
          0,
        );
        await service.owner.pruneCredentialUseHistory();
        expect(repo.credentialBatches, hasLength(1));
        expect(
          service.agent.showOwnOperation(
            fixture.session,
            'op-000000',
          )['requestId'],
          fixture.request.id,
        );
        await expectLater(
          service.agent.requestCredentialBatch(
            fixture.session,
            fixture.request.deviceId,
            fixture.input,
            operationId: 'op-000000',
          ),
          throwsA(
            isA<CredentialUseFailure>().having(
              (e) => e.code,
              'code',
              'operation_conflict',
            ),
          ),
        );
        service.agent.endSession(fixture.session);
        final preview = await service.owner.previewAuditRetention(30);
        expect(preview.credentialRequests, 1);
        expect(preview.credentialExecutions, 2);
        await service.owner.setAuditRetention(30, confirmation: preview);
        expect(repo.credentialBatches, isEmpty);
        expect(repo.credentialBatchOperations, isEmpty);
        expect(repo.credentialProgramOperations, isEmpty);
        expect(
          () => service.agent.showOwnOperation(fixture.session, 'op-000000'),
          throwsA(isA<AccessFailure>()),
        );
      },
    );
  }

  test(
    'unknown fill survives retention until review and the review itself ages out',
    () async {
      var now = DateTime.utc(2026, 11, 1);
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo, clock: () => now);
      addTearDown(service.close);
      final f = OperationHistoryFixture(service, repo, now);
      await f.open(program: false);
      final initial = CredentialBatchOperation(
        requestId: f.request.id,
        operationId: 'unknown-fill',
        sessionBinding: f.request.sessionBinding,
        fingerprint: 'sha256:${'a' * 64}',
        createdAt: now,
        itemIds: ['b1'],
      );
      await repo.commitCredentialBatch(
        f.request,
        expectedRevision: f.request.revision,
        operation: initial,
        expectedOperationRevision: 0,
        validate: () {},
      );
      await repo.commitCredentialBatch(
        f.request,
        expectedRevision: f.request.revision,
        operation: initial.changed(
          state: CredentialBatchOperationState.unknown,
          errorCode: 'execution_unknown',
          finishedAt: now,
        ),
        expectedOperationRevision: 1,
        validate: () {},
      );
      service.agent.endSession(f.session);
      now = now.add(const Duration(days: 100));
      await service.owner.pruneCredentialUseHistory();
      expect(repo.credentialBatches, hasLength(1));
      await service.owner.acknowledgeCredentialBatchOperation(
        f.request.id,
        initial.operationId,
        ownerOperationId: 'review-unknown',
        revision: 2,
      );
      await service.owner.pruneCredentialUseHistory();
      expect(repo.credentialBatches, hasLength(1));
      now = now.add(const Duration(days: 100));
      await service.owner.pruneCredentialUseHistory();
      expect(repo.credentialBatches, isEmpty);
    },
  );

  test('an appended operation invalidates a stale retention unit', () async {
    final repo = MemoryInformationRepository();
    final now = DateTime.utc(2026, 11, 1);
    final service = InformationService(repository: repo, clock: () => now);
    addTearDown(service.close);
    final f = OperationHistoryFixture(service, repo, now);
    await f.open(program: false, count: 1);
    final plan = CredentialBatchHistoryPrune(
      requests: repo.credentialBatches,
      operations: repo.credentialBatchOperations,
      programs: repo.credentialProgramOperations,
    );
    await f.append('appended-after-preview');
    await expectLater(
      repo.pruneCredentialBatchHistory(plan, validate: () {}),
      throwsA(isA<CredentialUseFailure>()),
    );
    expect(repo.credentialBatches, hasLength(1));
    expect(repo.credentialBatchOperations, hasLength(2));
  });

  for (final program in [false, true]) {
    test(
      '${program ? 'preparing program' : 'checking fill'} keeps the whole ended request',
      () async {
        var now = DateTime.utc(2026, 11, 1);
        final repo = MemoryInformationRepository();
        final service = InformationService(repository: repo, clock: () => now);
        addTearDown(service.close);
        final f = OperationHistoryFixture(service, repo, now);
        await f.open(program: program, count: 1);
        await f.append('unfinished-operation', finish: false);
        service.agent.endSession(f.session);
        now = now.add(const Duration(days: 100));
        expect(
          (await service.owner.previewAuditRetention(30)).credentialRequests,
          0,
        );
        await service.owner.pruneCredentialUseHistory();
        expect(repo.credentialBatches, hasLength(1));
        expect(
          program
              ? repo.credentialProgramOperations.length
              : repo.credentialBatchOperations.length,
          2,
        );
      },
    );
  }
}
