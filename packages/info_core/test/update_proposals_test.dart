import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'add replace and remove preserve only the still-authorized field identities',
    () async {
      final repository = MemoryInformationRepository();
      final service = InformationService(repository: repository);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'host.invalid'),
        const FieldInput('User', '', 'user'),
        const FieldInput('Notes', '', 'private notes'),
      ]);
      final refs = item.fields.map((f) => FieldRef(item.id, f.id)).toList();
      final session = service.agent.openSession('authorized chat');
      final request = service.agent.request(session, 'all old fields', refs);
      service.owner.approve(request.id, refs);
      final grant = service.agent.claim(session, request.id);
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.replace(
            refs[0].fieldId,
            const FieldInput('Email', '', 'new.invalid'),
          ),
          FieldChange.remove(refs[2].fieldId),
          const FieldChange.add(FieldInput('Extra', '', 'new secret')),
        ]),
      );
      await service.owner.confirmUpdate(id, 1);
      final saved = service.owner.information.single;
      expect(saved.fields, hasLength(3));
      expect(
        await Future<String>.value(service.agent.read(grant.token, refs[1])),
        'user',
      );
      for (final ref in [
        refs[0],
        refs[2],
        ...saved.fields
            .where((f) => f.id != refs[1].fieldId)
            .map((f) => FieldRef(saved.id, f.id)),
      ]) {
        await expectLater(
          Future<String>.sync(() => service.agent.read(grant.token, ref)),
          throwsA(isA<AccessFailure>()),
        );
      }
      // Rehydrating an old identity at the repository seam simulates a later
      // owner restore. Removal must stay terminal for the original grant.
      await repository.save(item);
      await expectLater(
        Future<String>.sync(() => service.agent.read(grant.token, refs[0])),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        await Future<String>.value(service.agent.read(grant.token, refs[1])),
        'user',
      );
      final fresh = service.agent.request(session, 'restored field', [refs[0]]);
      service.owner.approve(fresh.id, [refs[0]]);
      expect(
        await Future<String>.value(
          service.agent.read(
            service.agent.claim(session, fresh.id).token,
            refs[0],
          ),
        ),
        'host.invalid',
      );
    },
  );
  test(
    'concurrent confirmations of the same base version have one winner',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'initial.invalid'),
      ]);
      final session = service.agent.openSession('writer');
      final first = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, 'first.invalid'),
        ]),
      );
      final second = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, 'second.invalid'),
        ]),
      );
      final results = await Future.wait([
        for (final id in [first, second])
          service.owner
              .confirmUpdate(id, 1)
              .then<Object>((item) => item, onError: (Object e) => e),
      ]);
      expect(results.whereType<UpdateReceipt>(), hasLength(1));
      expect(
        results.whereType<AccessFailure>().single.status,
        'proposal_conflict',
      );
      expect(
        service.owner.information.single.fields.single.value,
        'first.invalid',
      );
      expect(service.owner.informationRevisions, hasLength(1));
    },
  );
  test(
    'stale proposal conflicts without clobbering a manual edit; rejection stays final',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'INITIAL-SECRET'),
      ]);
      final session = service.agent.openSession('writer');
      final other = service.agent.openSession('other');
      final field = FieldRef(item.id, item.fields.single.id);
      final baseVersion = service.agent.catalog().single['version'] as int;
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, baseVersion, [
          FieldChange.correct(field.fieldId, 'STALE-SECRET'),
        ]),
      );
      service.owner.previewUpdate(id);
      await service.owner.correctValue(field, 'MANUAL-SECRET');
      await expectLater(
        service.owner.confirmUpdate(id, 1),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'proposal_conflict',
          ),
        ),
      );
      expect(
        service.owner.information.single.fields.single.value,
        'MANUAL-SECRET',
      );
      expect(service.agent.updateStatus(session, id), {
        'status': 'conflicted',
        'proposalId': id,
      });
      expect(
        () => service.agent.updateStatus(other, id),
        throwsA(isA<AccessFailure>()),
      );
      final rejected = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 2, [
          FieldChange.correct(field.fieldId, 'REJECTED-SECRET'),
        ]),
      );
      await service.owner.rejectUpdate(rejected, 1);
      await expectLater(
        service.owner.confirmUpdate(rejected, 1),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        service.agent.updateStatus(session, rejected)['status'],
        'rejected',
      );
      expect(service.owner.informationRevisions, hasLength(1));
    },
  );
  test(
    'only owner confirmation applies a versioned correction and keeps its grant',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation(
        'Server',
        'Old public description',
        [const FieldInput('Host', 'Address', 'OLD-PRIVATE')],
      );
      final ref = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('update chat');
      final request = service.agent.request(session, 'connect', [ref]);
      service.owner.approve(request.id, [ref]);
      final grant = service.agent.claim(session, request.id);
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, item.version, [
          FieldChange.correct(ref.fieldId, 'NEW-PRIVATE'),
        ], description: 'Reviewed public description'),
      );
      expect(
        await Future<String>.value(service.agent.read(grant.token, ref)),
        'OLD-PRIVATE',
      );
      expect(
        service.agent.updateStatus(session, id).toString(),
        isNot(contains('OLD-PRIVATE')),
      );
      final preview = service.owner.previewUpdate(id);
      expect(preview.before.fields.single.value, 'OLD-PRIVATE');
      expect(preview.after.fields.single.value, 'NEW-PRIVATE');
      expect(preview.after.description, 'Reviewed public description');
      final saved = await service.owner.confirmUpdate(
        id,
        preview.proposal.version,
      );
      expect(saved.version, 2);
      expect(service.owner.information.single.fields.single.id, ref.fieldId);
      expect(
        await Future<String>.value(service.agent.read(grant.token, ref)),
        'NEW-PRIVATE',
      );
      expect(
        (await service.owner.confirmUpdate(
          id,
          preview.proposal.version,
        )).version,
        2,
      );
      expect(
        service.owner.informationRevisions.single.item.fields.single.value,
        'OLD-PRIVATE',
      );
      expect(service.agent.updateStatus(session, id)['status'], 'confirmed');
      expect(
        service.owner.updateProposals.single.toJson().toString(),
        isNot(contains('PRIVATE')),
      );
    },
  );
}
