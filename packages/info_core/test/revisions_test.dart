import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner restores a past value as a new current version for an existing grant',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'old.invalid'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('fictional chat');
      final request = service.agent.request(session, 'deployment', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      now = now.add(const Duration(minutes: 1));
      await service.owner.correctValue(field, 'new.invalid');
      expect(await service.agent.read(grant.token, field), 'new.invalid');
      final revisions = await service.owner.revisionsFor(item.id);
      expect(revisions.single.item.version, 1);
      final preview = service.owner.previewRevision(item.id, 1, 2);
      expect(preview.changes.single.before?.value, 'new.invalid');
      expect(preview.changes.single.after?.value, 'old.invalid');
      final restored = await service.owner.restoreRevision(item.id, 1, 2);
      expect(restored.version, 3);
      expect(restored.fields.single.version, 3);
      expect(await service.agent.read(grant.token, field), 'old.invalid');
      expect(
        (await service.owner.revisionsFor(item.id)).map((r) => r.item.version),
        [2, 1],
      );
      expect(
        service.agent.catalog().toString(),
        isNot(contains('old.invalid')),
      );
    },
  );
  test(
    'deleted identities require recycle restore and never revive an old grant',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      const host = FieldRef('demo-server', 'host');
      const user = FieldRef('demo-server', 'username');
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'connect', [host, user]);
      service.owner.approve(request.id, [host, user]);
      final token = service.agent.claim(session, request.id).token;
      final entry = await service.owner.deleteInformation(
        'demo-server',
        1,
        fieldId: 'host',
      );
      expect(
        service.owner
            .previewRevision('demo-server', 1, 2)
            .requiresRecycleRestore,
        isTrue,
      );
      await expectLater(
        service.owner.restoreRevision('demo-server', 1, 2),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'recycle_restore_required',
          ),
        ),
      );
      expect(service.owner.information.single.version, 2);
      await service.owner.restoreRecycled(entry.id);
      await service.owner.correctValue(user, 'corrected-user');
      final restored = await service.owner.restoreRevision('demo-server', 1, 4);
      expect(restored.version, 5);
      await expectLater(
        service.agent.read(token, host),
        throwsA(isA<AccessFailure>()),
      );
      expect(await service.agent.read(token, user), 'demo-user');
      final restoredHost = FieldRef(
        'demo-server',
        restored.fields.firstWhere((f) => f.id != 'username').id,
      );
      final fresh = service.agent.request(session, 'restored host', [
        restoredHost,
      ]);
      service.owner.approve(fresh.id, [restoredHost]);
      expect(
        await service.agent.read(
          service.agent.claim(session, fresh.id).token,
          restoredHost,
        ),
        'demo.example.invalid',
      );
      await service.owner.deleteInformation('demo-server', 5);
      await expectLater(
        service.owner.restoreRevision('demo-server', 1, 5),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'recycle_restore_required',
          ),
        ),
      );
    },
  );

  test(
    'restore checks concurrent versions and removals enter recycle without expanding grants',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final session = service.agent.openSession('proposer');
      final proposal = await service.agent.submitUpdate(
        session,
        UpdateInput('demo-server', 1, [
          const FieldChange.add(FieldInput('Email', '', 'new.invalid')),
        ]),
      );
      await service.owner.confirmUpdate(proposal, 1);
      final added = service.owner.information.single.fields.last;
      final ref = FieldRef('demo-server', added.id);
      final request = service.agent.request(session, 'new field', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      final preview = service.owner.previewRevision('demo-server', 1, 2);
      expect(preview.changes.single.before?.id, added.id);
      expect(preview.changes.single.after, isNull);
      final outcomes = await Future.wait([
        service.owner
            .restoreRevision('demo-server', 1, 2)
            .then<Object>((v) => v, onError: (Object e) => e),
        service.owner
            .restoreRevision('demo-server', 1, 2)
            .then<Object>((v) => v, onError: (Object e) => e),
      ]);
      expect(outcomes.whereType<InformationItem>(), hasLength(1));
      expect(
        outcomes.whereType<AccessFailure>().single.status,
        'revision_conflict',
      );
      expect(service.owner.information.single.version, 3);
      expect(
        service.owner.recycleEntries.single.snapshot!.fields.single.id,
        added.id,
      );
      await service.owner.restoreRecycled(
        service.owner.recycleEntries.single.id,
      );
      await expectLater(
        service.agent.read(token, ref),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    '30 day retention cleans only old versions and remains gone after time rollback',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final repository = MemoryInformationRepository();
      final service = InformationService(
        repository: repository,
        clock: () => now,
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation('Test', '', [
        const FieldInput('Value', '', 'one'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      await service.owner.correctValue(ref, 'two');
      now = now.add(const Duration(days: 1));
      await service.owner.correctValue(ref, 'three');
      now = DateTime.utc(2026, 10, 31);
      expect(service.owner.informationRevisions.map((r) => r.item.version), [
        2,
      ]);
      await service.owner.purgeRevisions();
      expect(repository.revisionPurgeFacts.single.version, 1);
      expect(service.owner.information.single.fields.single.value, 'three');
      now = DateTime.utc(2026, 10, 2);
      expect(
        (await service.owner.revisionsFor(item.id)).map((r) => r.item.version),
        [2],
      );
      await expectLater(
        service.owner.restoreRevision(item.id, 1, 3),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'revision_unavailable',
          ),
        ),
      );
    },
  );
  test(
    'failed restore storage preserves current content and its active grant',
    () async {
      final repository = UnavailableRevisionStorage();
      final service = InformationService(repository: repository);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Test', '', [
        const FieldInput('Value', '', 'old'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      await service.owner.correctValue(ref, 'current');
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'read current', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      await expectLater(
        service.owner.restoreRevision(item.id, 1, 2),
        throwsStateError,
      );
      expect(service.owner.information.single.version, 2);
      expect(await service.agent.read(token, ref), 'current');
      expect(
        (await service.owner.revisionsFor(item.id)).map((r) => r.item.version),
        [1],
      );
      expect(service.owner.recycleEntries, isEmpty);
    },
  );
}

class UnavailableRevisionStorage extends MemoryInformationRepository {
  @override
  Future<void> commitRecycleChange({
    required String itemId,
    InformationItem? item,
    InformationRevision? previous,
    required List<RecycleEntry> entries,
    required List<RecycleFact> facts,
    DeleteProposal? proposal,
    InformationLifecycleReceipt? lifecycleReceipt,
    void Function()? validate,
  }) async => throw StateError('external storage unavailable');
}
