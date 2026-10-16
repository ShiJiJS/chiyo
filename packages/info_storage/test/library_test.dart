import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'owner edit and explicit restoration provenance survive reopen and a full backup',
    () async {
      final dir = await Directory.systemTemp.createTemp('info-owner-library-');
      addTearDown(() => dir.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${dir.path}/source',
        keys,
      );
      var service = InformationService(repository: repo);
      final item = await service.owner.createInformation('Docs', 'public', [
        const FieldInput('URL', '', 'original'),
      ]);
      final old = item.fields.single.id;
      await service.owner.editInformation(
        item.id,
        1,
        name: 'Docs',
        description: 'public',
        changes: [FieldChange.remove(old)],
      );
      final restored = await service.owner.restoreRecycled(
        service.owner.recycleEntries.single.id,
      );
      final fresh = restored.fields.single.id;
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${dir.path}/source',
        keys,
      );
      service = InformationService(repository: repo);
      expect(service.owner.information.single.fields.single.id, fresh);
      expect(fresh, isNot(old));
      await service.owner.correctValue(FieldRef(item.id, fresh), 'changed');
      expect(
        (await service.owner.restoreRevision(
          item.id,
          1,
          4,
        )).fields.single.value,
        'original',
      );
      final recovery = await repo.backups.enable();
      final backup = '${dir.path}/full.aimbackup';
      await repo.backups.exportTo(backup);
      await service.close();
      await repo.close();
      final target = await EncryptedInformationRepository.open(
        '${dir.path}/target',
        TestKeyStore(),
      );
      addTearDown(target.close);
      await target.backups.restoreFrom(backup, recovery);
      final targetService = InformationService(repository: target);
      addTearDown(targetService.close);
      expect(
        targetService.owner.recycleFacts
            .firstWhere((f) => f.kind == RecycleFactKind.restored)
            .restoredFieldIds[old],
        fresh,
      );
      await targetService.owner.correctValue(FieldRef(item.id, fresh), 'again');
      final current = targetService.owner.information.single;
      expect(
        (await targetService.owner.restoreRevision(
          item.id,
          1,
          current.version,
        )).fields.single.id,
        fresh,
      );
    },
  );
}
