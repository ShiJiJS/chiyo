import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'proposal queue is bounded and separates pending conflicts and receipts',
    () async {
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      final owner = service.owner;
      final session = service.agent.openSession('review chat');
      final ids = <String>[];
      for (var n = 0; n < 12; n++) {
        now = now.add(const Duration(seconds: 1));
        ids.add(
          await service.agent.submitImport(session, [
            ImportItemInput('Import $n', '', [
              const FieldInput('URL', '', 'hidden-value'),
            ]),
          ]),
        );
      }
      final first = owner.queryProposals(limit: 3);
      expect(first.entries.map((entry) => entry.id), ids.reversed.take(3));
      expect(first.total, 12);
      expect(
        owner.queryProposals(offset: 3, limit: 3).entries.first.id,
        ids[8],
      );
      expect(owner.queryProposals(search: 'hidden-value').entries, isEmpty);
      await owner.confirmImport(ids.last, 1, owner.importProposals.last.items);
      final item = owner.information.single;
      final update = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, 'submitted'),
        ]),
      );
      await owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'manual',
      );
      final conflict = owner.queryProposals(search: update).entries.single;
      expect(conflict.status, ProposalStatus.conflicted);
      expect(conflict.changeCount, 1);
      final missingField = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 2, [
          const FieldChange.correct('missing-field', 'submitted'),
        ]),
      );
      expect(
        owner.queryProposals(search: missingField).entries.single.status,
        ProposalStatus.conflicted,
      );
      expect(
        owner
            .queryProposals(filter: ProposalFilter.pending)
            .entries
            .any((entry) => entry.id == update),
        isTrue,
      );
      expect(
        owner.queryProposals(filter: ProposalFilter.handled).entries.single.id,
        ids.last,
      );
      expect(
        () => owner.queryProposals(limit: 101),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'owner confirms one reviewed update without saving its draft early',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final item = await owner.createInformation('Docs', 'Old public', [
        const FieldInput('URL', 'Old field description', 'old.example'),
      ]);
      final directory = await owner.createDirectory('Work');
      final tag = await owner.createTag('Reviewed');
      final session = service.agent.openSession('proposal chat');
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, 'submitted.example'),
        ]),
      );
      final review = UpdateReview(
        UpdateInput(
          item.id,
          1,
          [FieldChange.correct(item.fields.single.id, 'reviewed.example')],
          name: 'Reviewed docs',
          description: 'Reviewed public',
        ),
        directoryId: directory.id,
        tagIds: [tag.id],
        fieldDescriptions: {
          item.fields.single.id: 'Reviewed field description',
        },
      );
      final preview = owner.previewUpdate(id, review: review);
      expect(preview.after.name, 'Reviewed docs');
      expect(owner.information.single.fields.single.value, 'old.example');
      final receipt = await owner.confirmUpdate(id, 1, review: review);
      final current = owner.information.single;
      expect(receipt!.itemId, item.id);
      expect(current.name, 'Reviewed docs');
      expect(current.description, 'Reviewed public');
      expect(current.directoryId, directory.id);
      expect(current.tagIds, [tag.id]);
      expect(current.fields.single.id, item.fields.single.id);
      expect(current.fields.single.value, 'reviewed.example');
      expect(current.fields.single.description, 'Reviewed field description');
      expect(owner.updateProposals.single.input.changes, isEmpty);
      expect((await owner.confirmUpdate(id, 1))!.version, receipt.version);
      expect(owner.information.single.version, 2);
    },
  );
}
