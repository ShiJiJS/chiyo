import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'schema ten upgrades unknown timestamps to null without inventing creation facts',
    () async {
      final folder = await Directory.systemTemp.createTemp('info-time-legacy-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      await store.save(
        InformationItem('legacy', 'Legacy', '', 1, const [
          InformationField('field', 'Value', '', 'old', 1),
        ]),
      );
      await store.close();
      final fixture = sqlite3.open('${folder.path}/library.db');
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      fixture.execute('PRAGMA key = "x\'$hex\'"');
      fixture.execute('ALTER TABLE information_items DROP COLUMN created_at');
      fixture.execute('ALTER TABLE information_items DROP COLUMN modified_at');
      fixture.execute('PRAGMA user_version = 10');
      fixture.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      expect(store.items.single.createdAt, isNull);
      expect(store.items.single.modifiedAt, isNull);
      final changedAt = DateTime.utc(2026, 10, 16);
      var service = InformationService(
        repository: store,
        clock: () => changedAt,
      );
      await service.owner.correctValue(
        const FieldRef('legacy', 'field'),
        'edited',
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store, clock: () => changedAt);
      addTearDown(service.close);
      expect(service.owner.information.single.createdAt, isNull);
      expect(service.owner.information.single.modifiedAt, changedAt);
      expect(service.owner.informationRevisions.single.item.createdAt, isNull);
    },
  );

  test(
    'encrypted reopening preserves known item and prior-version times including clock rollback',
    () async {
      final folder = await Directory.systemTemp.createTemp('info-time-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      final created = DateTime.utc(2026, 10, 16, 12);
      var now = created;
      var service = InformationService(repository: store, clock: () => now);
      final item = await service.owner.createInformation('Item', '', [
        const FieldInput('Value', '', 'old'),
      ]);
      now = created.subtract(const Duration(hours: 1));
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'current',
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store, clock: () => now);
      addTearDown(service.close);
      expect(service.owner.information.single.createdAt, created);
      expect(service.owner.information.single.modifiedAt, now);
      expect(
        service.owner.informationRevisions.single.item.modifiedAt,
        created,
      );
    },
  );
}
