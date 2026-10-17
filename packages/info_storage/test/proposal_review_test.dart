import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

import 'storage_test.dart' show TestKeyStore;

void main() {
  test('reviewed replacement and metadata commit once and survive encrypted reopening', () async {
    final folder = await Directory.systemTemp.createTemp(
      'info-proposal-review-',
    );
    addTearDown(() => folder.delete(recursive: true));
    final keys = TestKeyStore();
    var repo = await EncryptedInformationRepository.open(folder.path, keys);
    var service = InformationService(repository: repo);
    final owner = service.owner;
    final item = await owner.createInformation('Original', 'Public before', [
      const FieldInput('URL', 'URL before', 'before.example'),
      const FieldInput('Note', 'Old meaning', 'original note'),
    ]);
    final directory = await owner.createDirectory('Reviewed directory');
    final tag = await owner.createTag('Reviewed tag');
    final id = await service.agent.submitUpdate(
      service.agent.openSession('Review modification'),
      UpdateInput(item.id, 1, [
        FieldChange.correct(item.fields.first.id, 'submitted.example'),
      ]),
    );
    final invalid = UpdateReview(
      UpdateInput(item.id, 1, [
        FieldChange.correct(item.fields.first.id, 'must-not-commit.example'),
      ]),
      tagIds: ['missing-tag'],
    );
    await expectLater(
      owner.confirmUpdate(id, 1, review: invalid),
      throwsA(isA<AccessFailure>()),
    );
    expect(owner.information.single.version, 1);
    expect(owner.informationRevisions, isEmpty);
    expect(owner.recycleEntries, isEmpty);
    expect(owner.updateProposals.single.state, UpdateProposalState.pending);
    final review = UpdateReview(
      UpdateInput(
        item.id,
        1,
        [
          FieldChange.correct(item.fields.first.id, 'reviewed.example'),
          FieldChange.replace(
            item.fields.last.id,
            const FieldInput('Note', 'New meaning', 'reviewed note'),
          ),
        ],
        name: 'Reviewed',
        description: 'Public after',
      ),
      directoryId: directory.id,
      tagIds: [tag.id],
      fieldDescriptions: {item.fields.first.id: 'Reviewed URL'},
    );
    final receipt = await owner.confirmUpdate(id, 1, review: review);
    final fresh = owner.information.single.fields.last.id;
    expect(fresh, isNot(item.fields.last.id));
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(folder.path, keys);
    service = InformationService(repository: repo);
    addTearDown(repo.close);
    addTearDown(service.close);
    final current = service.owner.information.single;
    expect(current.id, item.id);
    expect(current.name, 'Reviewed');
    expect(current.description, 'Public after');
    expect(current.directoryId, directory.id);
    expect(current.tagIds, [tag.id]);
    expect(current.fields.first.id, item.fields.first.id);
    expect(current.fields.first.value, 'reviewed.example');
    expect(current.fields.first.description, 'Reviewed URL');
    expect(current.fields.last.id, fresh);
    expect(current.fields.last.value, 'reviewed note');
    expect(
        service.owner.recycleEntries.single.snapshot!.fields.single.id,
      item.fields.last.id,
    );
    expect(
      service.owner.informationRevisions.single.item.fields.first.value,
      'before.example',
    );
    expect(service.owner.updateProposals.single.input.changes, isEmpty);
    expect((await service.owner.confirmUpdate(id, 1)).version, receipt.version);
    expect(service.owner.informationRevisions, hasLength(1));
  });
}
