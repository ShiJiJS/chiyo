import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/legacy_attachment_fixture.dart';

void main() {
  test(
    'separate a legacy original once without losing facts, bytes or history',
    () async {
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      final original = await createLegacyAttachment(service, repo);
      final field = original.fields.first;
      final receipt = await service.owner.separateInformationAttachment(
        operationId: 'separate-original',
        itemId: original.id,
        expectedVersion: original.version,
        fieldId: field.id,
        name: '独立原件',
        templateId: 'file',
      );
      final source = repo.items.singleWhere((i) => i.id == original.id);
      final file = repo.items.singleWhere((i) => i.id == receipt.itemId);
      expect(source.fields.single.value, '重要事实');
      expect(source.layout!.snapshot['retainedFields'], isEmpty);
      expect(file.fields.single.id, isNot(field.id));
      expect(file.fields.single.attachment, field.attachment);
      expect(file.layout!.relations['related']!.single.id, source.id);
      expect(
        (await service.owner.informationAttachmentVersions(
          field.attachment!.attachmentId,
        )).length,
        2,
      );
      expect(
        (await service.owner.readInformationAttachment(
          file.fields.single.attachment!,
        )).bytes,
        utf8.encode('原文0'),
      );
      expect(repo.informationRevisions.single.item.fields.first.id, field.id);
      final repeated = await service.owner.separateInformationAttachment(
        operationId: 'separate-original',
        itemId: original.id,
        expectedVersion: original.version,
        fieldId: field.id,
        name: '独立原件',
        templateId: 'file',
      );
      expect(repeated.toJson(), receipt.toJson());
      expect(repo.items.length, 2);
      await expectLater(
        service.owner.separateInformationAttachment(
          operationId: 'separate-original',
          itemId: original.id,
          expectedVersion: original.version,
          fieldId: field.id,
          name: '另一个意图',
          templateId: 'file',
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
