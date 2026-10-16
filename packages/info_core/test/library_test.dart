import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  for (final invalidProvenance in ['cycle', 'ambiguous']) {
    test('history refuses $invalidProvenance restoration provenance', () async {
      final repository = MemoryInformationRepository();
      final service = InformationService(repository: repository);
      addTearDown(service.close);
      final owner = service.owner;
      final item = await owner.createInformation('Docs', '', [
        const FieldInput('URL', '', 'original'),
      ]);
      final original = item.fields.single.id;
      await owner.deleteInformation(item.id, 1, fieldId: original);
      final now = DateTime.now().toUtc();
      final links = invalidProvenance == 'cycle'
          ? [
              {original: 'intermediate'},
              {'intermediate': original},
            ]
          : [
              {original: 'first'},
              {original: 'second'},
            ];
      // Characterize the public owner boundary with malformed persisted facts.
      // These are neither an owner restore nor a name-based identity inference.
      await repository.commitRecycleChange(
        itemId: item.id,
        item: owner.information.single,
        entries: const [],
        facts: [
          for (var n = 0; n < links.length; n++)
            RecycleFact(
              'invalid-$n',
              item.id,
              links[n].keys,
              3 + n,
              RecycleFactKind.restored,
              now,
              restoredFieldIds: links[n],
            ),
        ],
      );
      expect(
        () =>
            owner.previewRevision(item.id, 1, owner.information.single.version),
        throwsA(
          isA<AccessFailure>().having(
            (failure) => failure.status,
            'status',
            'revision_conflict',
          ),
        ),
      );
      expect(owner.information.single.fields, isEmpty);
    });
  }
  test(
    'history does not guess a deleted field by another field with the same name',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final item = await owner.createInformation('Same names', '', [
        const FieldInput('URL', '', 'one'),
        const FieldInput('URL', '', 'two'),
      ]);
      await owner.deleteInformation(item.id, 1, fieldId: item.fields.first.id);
      final current = await owner.editInformation(
        item.id,
        2,
        name: item.name,
        description: '',
        changes: [const FieldChange.add(FieldInput('URL', '', 'unrelated'))],
      );
      expect(
        owner
            .previewRevision(item.id, 1, current.version)
            .requiresRecycleRestore,
        isTrue,
      );
      final restored = await owner.restoreRecycled(
        owner.recycleEntries.single.id,
      );
      final previous = owner.previewRevision(item.id, 1, restored.version);
      expect(previous.requiresRecycleRestore, isFalse);
      expect(previous.restored.fields.first.id, restored.fields.last.id);
      expect(previous.restored.fields.first.value, 'one');
      expect(previous.restored.fields.last.id, item.fields.last.id);
    },
  );
  test(
    'directory rename and move retain identity and reject descendant cycles',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final root = await owner.createDirectory('Root');
      final child = await owner.createDirectory('Child', parentId: root.id);
      await expectLater(
        owner.updateDirectory(root.id, 'Root', parentId: child.id),
        throwsA(isA<AccessFailure>()),
      );
      final renamed = await owner.updateDirectory(child.id, 'Renamed');
      expect(renamed.id, child.id);
      expect(renamed.parentId, isNull);
      expect(renamed.version, 2);
    },
  );
  test(
    'history follows only explicit recycle provenance through repeated restores',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final item = await owner.createInformation('Docs', '', [
        const FieldInput('URL', '', 'original'),
      ]);
      final old = item.fields.single.id;
      await owner.deleteInformation(item.id, 1, fieldId: old);
      final b = await owner.restoreRecycled(owner.recycleEntries.single.id);
      await owner.correctValue(
        FieldRef(item.id, b.fields.single.id),
        'corrected',
      );
      final history = await owner.restoreRevision(item.id, 1, 4);
      expect(history.fields.single.id, b.fields.single.id);
      expect(history.fields.single.value, 'original');
      await owner.deleteInformation(item.id, 5, fieldId: b.fields.single.id);
      final c = await owner.restoreRecycled(owner.recycleEntries.single.id);
      final next = await owner.restoreRevision(item.id, 1, c.version);
      expect(next.fields.single.id, c.fields.single.id);
      expect(next.fields.single.id, isNot(old));
      expect(next.fields.single.value, 'original');
      final roundTrip = RecycleFact.fromJson(
        Map<String, dynamic>.from(
          owner.recycleFacts
              .firstWhere((f) => f.kind == RecycleFactKind.restored)
              .toJson(),
        ),
      );
      expect(roundTrip.restoredFieldIds[old], b.fields.single.id);
    },
  );
  test(
    'owner template creation saves selected organization in the first version',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final directory = await owner.createDirectory('Work');
      final tag = await owner.createTag('Daily');
      final template = await owner.createTemplate('Entry', 'public', [
        const TemplateFieldInput('Note', '', kind: FieldKind.textNote),
      ]);
      final item = await owner.createInformationFromTemplate(
        template.id,
        1,
        'Docs',
        'Public',
        {template.fields.single.id: 'private note'},
        directoryId: directory.id,
        tagIds: [tag.id],
      );
      expect(item.version, 1);
      expect(item.directoryId, directory.id);
      expect(item.tagIds, [tag.id]);
      expect(item.fields.single.kind, FieldKind.textNote);
      expect(owner.informationRevisions, isEmpty);
      await expectLater(
        owner.createInformation(
          'Invalid',
          '',
          [const FieldInput('F', '', 'V')],
          tagIds: ['missing'],
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(owner.information, hasLength(1));
    },
  );
  test(
    'owner library query pages stable identities, descendants and all selected tags including empty items',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final project = await owner.createDirectory('Project');
      final child = await owner.createDirectory(
        'Services',
        parentId: project.id,
      );
      final a = await owner.createTag('A');
      final b = await owner.createTag('B');
      for (final name in ['Charlie', 'Alpha', 'Bravo']) {
        final item = await owner.createInformation(name, 'Public entry', [
          const FieldInput('URL', '', 'private'),
        ]);
        await owner.organizeInformation(
          item.id,
          directoryId: child.id,
          tagIds: name == 'Charlie' ? [a.id] : [a.id, b.id],
        );
        if (name == 'Alpha') {
          await owner.deleteInformation(
            item.id,
            2,
            fieldId: item.fields.single.id,
          );
        }
      }
      final first = owner.queryInformation(
        directoryId: project.id,
        tagIds: [a.id, b.id],
        limit: 1,
      );
      expect(first.items.single.name, 'Alpha');
      expect(first.total, 2);
      expect(
        owner
            .queryInformation(
              directoryId: project.id,
              includeDescendants: false,
            )
            .total,
        0,
      );
      expect(
        owner
            .queryInformation(
              directoryId: project.id,
              tagIds: [a.id, b.id],
              offset: 1,
              limit: 1,
            )
            .items
            .single
            .name,
        'Bravo',
      );
      expect(owner.queryInformation(search: 'missing').items, isEmpty);
      expect(
        () => owner.queryInformation(limit: 101),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => owner.queryInformation(tagIds: ['unknown']),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'explicit recycle restore gives removed fields fresh identities and needs a new grant',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final item = await owner.createInformation('Docs', '', [
        const FieldInput('URL', '', 'entry'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('reader');
      final request = service.agent.request(session, 'read', [ref]);
      owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      await owner.editInformation(
        item.id,
        1,
        name: 'Docs',
        description: '',
        changes: [FieldChange.remove(ref.fieldId)],
      );
      final restored = await owner.restoreRecycled(
        owner.recycleEntries.single.id,
      );
      expect(restored.id, item.id);
      expect(restored.fields.single.id, isNot(ref.fieldId));
      final fresh = FieldRef(item.id, restored.fields.single.id);
      await expectLater(
        service.agent.read(token, fresh),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.read(token, ref),
        throwsA(isA<AccessFailure>()),
      );
      final next = service.agent.request(session, 'restored field', [fresh]);
      owner.approve(next.id, [fresh]);
      expect(
        await service.agent.read(
          service.agent.claim(session, next.id).token,
          fresh,
        ),
        'entry',
      );
      expect(
        (await owner.history()).grants.first.fields.single.fieldId,
        ref.fieldId,
      );
    },
  );
  test(
    'owner edits values and organization atomically without an Agent proposal',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final directory = await owner.createDirectory('Project');
      final tag = await owner.createTag('Self hosted');
      final item = await owner.createInformation('Docs', 'Public', [
        const FieldInput('URL', 'Entry', 'old.example'),
        const FieldInput('Note', '', 'controlled', kind: FieldKind.textNote),
      ]);
      final ref = FieldRef(item.id, item.fields.first.id);
      final session = service.agent.openSession('reader');
      final request = service.agent.request(session, 'read', [ref]);
      owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      final edited = await owner.editInformation(
        item.id,
        1,
        name: 'Documentation',
        description: 'Public entry',
        directoryId: directory.id,
        tagIds: [tag.id],
        changes: [FieldChange.correct(ref.fieldId, 'new.example')],
        fieldDescriptions: {ref.fieldId: 'Public URL'},
      );
      expect(edited.id, item.id);
      expect(edited.version, 2);
      expect(edited.fields.first.id, ref.fieldId);
      expect(edited.fields.first.description, 'Public URL');
      expect(edited.directoryId, directory.id);
      expect(edited.tagIds, [tag.id]);
      expect(await service.agent.read(token, ref), 'new.example');
      expect(owner.updateProposals, isEmpty);
      expect(owner.importProposals, isEmpty);
      expect((await owner.revisionsFor(item.id)).single.item.name, 'Docs');
      await expectLater(
        owner.editInformation(
          item.id,
          1,
          name: 'Stale',
          description: '',
          changes: const [],
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'information_conflict',
          ),
        ),
      );
      expect(owner.information.single.name, 'Documentation');
    },
  );
}
