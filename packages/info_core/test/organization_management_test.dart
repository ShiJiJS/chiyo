import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Matcher fails(String status) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', status));

void main() {
  test(
    'tag removal rejects a changed impact review without partial cleanup',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final o = service.owner;
      final tag = await o.createTag('Reviewed');
      final item = await o.createInformation(
        'A',
        '',
        [const FieldInput('Text', '', 'fake')],
        tagIds: [tag.id],
      );
      final changed = await o.organizeInformation(item.id, tagIds: [tag.id]);
      await expectLater(
        o.deleteTag(
          tag.id,
          tag.version,
          reviewedInformation: {item.id: item.version},
        ),
        fails('organization_conflict'),
      );
      expect(o.tags.single.id, tag.id);
      expect(o.information.single.tagIds, [tag.id]);
      await o.deleteTag(
        tag.id,
        tag.version,
        reviewedInformation: {changed.id: changed.version},
      );
      expect(o.information.single.tagIds, isEmpty);
    },
  );
  test(
    'single-level names and sibling uniqueness, moves preserve identity',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final o = service.owner;
      final work = await o.createDirectory('Work');
      final personal = await o.createDirectory('Personal');
      final child = await o.createDirectory('Docs', parentId: work.id);
      await expectLater(
        o.createDirectory('work/docs'),
        fails('invalid_directory_name'),
      );
      await expectLater(
        o.createDirectory(r'work\docs'),
        fails('invalid_directory_name'),
      );
      await expectLater(
        o.createDirectory(' docs ', parentId: work.id),
        fails('duplicate_directory'),
      );
      await o.createDirectory('Docs', parentId: personal.id);
      await expectLater(
        o.updateDirectory(work.id, work.name, parentId: child.id),
        fails('invalid_information'),
      );
      final moved = await o.updateDirectory(
        child.id,
        'Docs',
        parentId: null,
        expectedVersion: 1,
      );
      expect(moved.id, child.id);
      expect(moved.version, 2);
      await expectLater(
        o.deleteDirectory(child.id, 1),
        fails('organization_conflict'),
      );
      await o.deleteDirectory(child.id, 2);
      final recreated = await o.createDirectory('Docs');
      expect(recreated.id, isNot(child.id));
    },
  );

  test('nonempty directory deletion rejects both items and children', () async {
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    addTearDown(service.close);
    final o = service.owner;
    final dir = await o.createDirectory('Project');
    final child = await o.createDirectory('Child', parentId: dir.id);
    await expectLater(
      o.deleteDirectory(dir.id, dir.version),
      fails('directory_not_empty'),
    );
    await o.deleteDirectory(child.id, child.version);
    await o.createInformation('Docs', '', [
      const FieldInput('Text', '', 'fake'),
    ], directoryId: dir.id);
    await expectLater(
      o.deleteDirectory(dir.id, dir.version),
      fails('directory_not_empty'),
    );
    expect(o.directories.single.id, dir.id);
  });

  test(
    'tag deletion cleans current relationships and preserves readable fields and history',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final o = service.owner;
      final tag = await o.createTag('Linux');
      await expectLater(o.createTag(' linux '), fails('duplicate_tag'));
      final item = await o.createInformation(
        'Server',
        '',
        [const FieldInput('Host', '', 'fake.example')],
        tagIds: [tag.id],
      );
      final session = service.agent.openSession('Test');
      final ref = FieldRef(item.id, item.fields.single.id);
      final request = service.agent.request(session, 'Read host', [ref]);
      o.approve(request.id, [ref]);
      await o.deleteTag(tag.id, tag.version);
      final updated = o.information.single;
      expect(updated.tagIds, isEmpty);
      expect(updated.version, item.version + 1);
      expect(updated.fields.single.id, ref.fieldId);
      expect(
        await service.agent.read(
          service.agent.claim(session, request.id).token,
          ref,
        ),
        'fake.example',
      );
      expect((await o.revisionsFor(item.id)).single.item.tagIds, [tag.id]);
      await o.restoreRevision(item.id, item.version, updated.version);
      expect(o.information.single.tagIds, isEmpty);
    },
  );

  test(
    'recycle restore skips removed categories, query unclassified and sorting remain coherent',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final o = service.owner;
      final dir = await o.createDirectory('Project');
      final tag = await o.createTag('Docs');
      final item = await o.createInformation(
        'A',
        '',
        [const FieldInput('Text', '', 'fake')],
        directoryId: dir.id,
        tagIds: [tag.id],
      );
      await o.createInformation('Z', '', [
        const FieldInput('Text', '', 'fake'),
      ]);
      final entry = await o.deleteInformation(item.id, item.version);
      await o.deleteDirectory(dir.id, dir.version);
      await o.deleteTag(tag.id, tag.version);
      final restored = await o.restoreRecycled(entry.id);
      expect(restored.directoryId, isNull);
      expect(restored.tagIds, isEmpty);
      expect(restored.fields.single.id, isNot(item.fields.single.id));
      expect(o.queryInformation(unclassifiedOnly: true).total, 2);
      expect(
        o.queryInformation(sortDescending: true, limit: 1).items.single.name,
        'Z',
      );
      await expectLater(
        o.organizeInformation(restored.id, expectedVersion: item.version),
        fails('information_conflict'),
      );
    },
  );
}
