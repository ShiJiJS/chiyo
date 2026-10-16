import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() async {
  test(
    'import submission cannot overwrite existing values or expand existing grants',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final original = await service.owner.createInformation('Existing', '', [
        const FieldInput('Host', '', 'original.invalid'),
      ]);
      final session = service.agent.openSession('chat');
      final ref = FieldRef(original.id, original.fields.single.id);
      final request = service.agent.request(session, 'existing only', [ref]);
      service.owner.approve(request.id, [ref]);
      final grant = service.agent.claim(session, request.id);
      final id = await service.agent.submitImport(session, [
        ImportItemInput('Existing', '', [
          const FieldInput('Host', '', 'new.invalid'),
        ]),
      ]);
      expect(await service.agent.read(grant.token, ref), 'original.invalid');
      final added = (await service.owner.confirmImport(
        id,
        1,
        service.owner.importProposals.single.items,
      )).single;
      expect(added.id, isNot(original.id));
      expect(added.fields.single.id, isNot(original.fields.single.id));
      expect(await service.agent.read(grant.token, ref), 'original.invalid');
      expect(
        () => service.agent.read(
          grant.token,
          FieldRef(added.id, added.fields.single.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
      final next = service.agent.request(session, 'new import', [
        FieldRef(added.id, added.fields.single.id),
      ]);
      service.owner.approve(next.id, [
        FieldRef(added.id, added.fields.single.id),
      ]);
      expect(
        await service.agent.read(
          service.agent.claim(session, next.id).token,
          FieldRef(added.id, added.fields.single.id),
        ),
        'new.invalid',
      );
    },
  );
  test(
    'reject and invalid review leave the entire batch unpublished',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final session = service.agent.openSession('chat');
      final original = [
        ImportItemInput('New', '', [const FieldInput('Host', '', 'private')]),
      ];
      final id = await service.agent.submitImport(session, original);
      await expectLater(
        service.owner.confirmImport(id, 1, [
          original.single,
          ImportItemInput('Invalid last entry', '', [
            const FieldInput('Host', '', 'private'),
          ], directoryId: 'missing'),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.information, isEmpty);
      expect(service.agent.importStatus(session, id)['status'], 'pending');
      await service.owner.rejectImport(id, 1);
      await expectLater(
        service.owner.confirmImport(id, 1, original),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.agent.importStatus(session, id)['status'], 'rejected');
      expect(service.agent.catalog(), isEmpty);
      await expectLater(
        service.agent.submitImport(session, List.filled(21, original.single)),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.importProposals, hasLength(1));
    },
  );
  test(
    'private batch becomes new information only after owner review, once',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final session = service.agent.openSession('Importing chat');
      final other = service.agent.openSession('Another chat');
      final id = await service.agent.submitImport(session, [
        ImportItemInput(
          'Suggested',
          'Public description',
          [
            const FieldInput('Host', 'Address', 'PRIVATE-IMPORT-VALUE'),
            const FieldInput(
              'Notes',
              '',
              'Private notes',
              kind: FieldKind.textNote,
            ),
          ],
          suggestedDirectory: 'Servers',
          suggestedTags: ['Project A'],
          suggestedTemplate: 'Server',
        ),
        ImportItemInput('Second', '', [
          const FieldInput('Email', '', 'second.invalid'),
        ]),
      ]);
      expect(service.agent.importStatus(session, id)['status'], 'pending');
      expect(
        service.agent.importStatus(session, id).toString(),
        isNot(contains('PRIVATE')),
      );
      expect(
        () => service.agent.importStatus(other, id),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.agent.catalog(), isEmpty);
      final directory = await service.owner.createDirectory(
        'Reviewed directory',
      );
      final tag = await service.owner.createTag('Reviewed tag');
      final reviewed = [
        ImportItemInput(
          'Reviewed',
          'Safe public description',
          [const FieldInput('Host', 'Address', 'reviewed.invalid')],
          directoryId: directory.id,
          tagIds: [tag.id],
        ),
        service.owner.importProposals.single.items.last,
      ];
      final result = await service.owner.confirmImport(id, 1, reviewed);
      expect(result, hasLength(2));
      expect(result.first.directoryId, directory.id);
      expect(result.first.tagIds, [tag.id]);
      expect(service.agent.importStatus(session, id)['status'], 'confirmed');
      expect(service.agent.catalog(), hasLength(2));
      final retry = await service.owner.confirmImport(id, 1, reviewed);
      expect(retry.map((i) => i.id), result.map((i) => i.id));
      expect(service.owner.information, hasLength(2));
      expect(
        () => service.agent.read(
          id,
          FieldRef(result.first.id, result.first.fields.first.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
