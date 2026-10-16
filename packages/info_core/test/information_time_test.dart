import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'confirmed imports start their clock at confirmation and unknown legacy creation stays unknown',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService(
        repository: MemoryInformationRepository([
          InformationItem('legacy', 'Legacy', '', 1, const [
            InformationField('field', 'Value', '', 'old', 1),
          ]),
        ]),
        clock: () => now,
      );
      addTearDown(service.close);
      final session = service.agent.openSession('importer');
      final batch = [
        ImportItemInput('Imported', '', [const FieldInput('Value', '', 'new')]),
      ];
      final proposal = await service.agent.submitImport(session, batch);
      now = now.add(const Duration(days: 1));
      final receipt = (await service.owner.confirmImport(
        proposal,
        1,
        batch,
      )).single;
      final imported = service.owner.information.singleWhere(
        (i) => i.id == receipt.id,
      );
      expect(imported.createdAt, now);
      expect(imported.modifiedAt, now);
      final changed = await service.owner.correctValue(
        const FieldRef('legacy', 'field'),
        'corrected',
      );
      expect(changed.createdAt, isNull);
      expect(changed.modifiedAt, now);
      expect(service.owner.informationRevisions.single.item.modifiedAt, isNull);
    },
  );

  test(
    'metadata proposals organization and recovery preserve creation and timestamp each committed change',
    () async {
      final created = DateTime.utc(2026, 10, 16);
      var now = created;
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      var item = await service.owner.createInformation('Item', '', [
        const FieldInput('Value', '', 'one'),
        const FieldInput('Second', '', 'two'),
      ]);
      void verify(InformationItem updated) {
        expect(updated.createdAt, created);
        expect(updated.modifiedAt, now);
        item = updated;
        now = now.add(const Duration(minutes: 1));
      }

      now = now.add(const Duration(minutes: 1));
      verify(
        await service.owner.updateCatalogMetadata(
          item.id,
          name: 'New name',
          description: 'Public',
          fieldDescriptions: {},
        ),
      );
      final directory = await service.owner.createDirectory('Folder');
      verify(
        await service.owner.organizeInformation(
          item.id,
          directoryId: directory.id,
        ),
      );
      final session = service.agent.openSession('writer');
      final proposal = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, item.version, [
          FieldChange.correct(item.fields.first.id, 'corrected'),
        ]),
      );
      now = now.add(const Duration(minutes: 1));
      await service.owner.confirmUpdate(proposal, 1);
      verify(service.owner.information.single);
      final entry = await service.owner.deleteInformation(
        item.id,
        item.version,
        fieldId: item.fields.last.id,
      );
      verify(service.owner.information.single);
      expect(entry.snapshot!.createdAt, created);
      verify(await service.owner.restoreRecycled(entry.id));
      verify(await service.owner.restoreRevision(item.id, 1, item.version));
      final whole = await service.owner.deleteInformation(
        item.id,
        item.version,
      );
      now = now.add(const Duration(minutes: 1));
      verify(await service.owner.restoreRecycled(whole.id));
    },
  );

  test(
    'creation and edits record actual owner clock facts without imposing chronological order',
    () async {
      final created = DateTime.utc(2026, 10, 16, 12);
      var now = created;
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      var item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'old.invalid'),
      ]);
      expect(item.createdAt, created);
      expect(item.modifiedAt, created);
      now = created.subtract(const Duration(hours: 1));
      item = await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'new.invalid',
      );
      expect(item.createdAt, created);
      expect(item.modifiedAt, now);
      expect(item.version, 2);
      expect(
        service.owner.informationRevisions.single.item.modifiedAt,
        created,
      );
      expect(service.agent.catalog().single.containsKey('createdAt'), isFalse);
      expect(service.agent.catalog().single.containsKey('modifiedAt'), isFalse);
    },
  );
}
