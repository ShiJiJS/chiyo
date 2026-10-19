import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'schema nine upgrade preserves encrypted revisions and restored current versions survive reopen',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'info-revision-upgrade-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      final item = await service.owner.createInformation('Original', '', [
        const FieldInput('Value', '', 'old'),
      ]);
      await service.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'new',
      );
      await service.close();
      await store.close();
      final fixture = sqlite3.open('${folder.path}/library.db');
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      fixture.execute('PRAGMA key = "x\'$hex\'"');
      fixture.execute('DROP TABLE revision_purge_facts');
      fixture.execute('DROP TABLE organization_tasks');
      fixture.execute('PRAGMA user_version = 9');
      fixture.execute('DROP TABLE library_format');
      fixture.execute('DROP TABLE information_deliveries');
      fixture.execute('DROP TABLE information_file_fields');
      fixture.execute('DROP TABLE information_attachment_versions');
      fixture.execute('DROP TABLE information_draft_commits');
      fixture.execute('DROP TABLE information_file_stages');
      fixture.execute('DROP TABLE credential_focused_fills');
      fixture.execute('DROP TABLE credential_operations');
      fixture.execute('DROP TABLE credential_runtime_requests');
      fixture.execute('ALTER TABLE information_items DROP COLUMN created_at');
      fixture.execute('ALTER TABLE information_items DROP COLUMN modified_at');
      fixture.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      expect(
        (await service.owner.revisionsFor(item.id)).single.item.version,
        1,
      );
      await service.owner.restoreRevision(item.id, 1, 2);
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store);
      addTearDown(service.close);
      expect(service.owner.information.single.version, 3);
      expect(service.owner.information.single.fields.single.value, 'old');
      expect(
        (await service.owner.revisionsFor(item.id)).map((r) => r.item.version),
        [2, 1],
      );
    },
  );
  test(
    'expired encrypted versions stay purged after reopening and clock rollback',
    () async {
      final folder = await Directory.systemTemp.createTemp('info-revisions-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var now = DateTime.utc(2026, 10, 1);
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store, clock: () => now);
      final item = await service.owner.createInformation('Test', '', [
        const FieldInput('Value', '', 'OLD-REVISION-SECRET-94815'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      await service.owner.correctValue(ref, 'CURRENT-SECRET-94815');
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store, clock: () => now);
      expect(
        (await service.owner.revisionsFor(
          item.id,
        )).single.item.fields.single.value,
        'OLD-REVISION-SECRET-94815',
      );
      now = now.add(const Duration(days: 30));
      await service.owner.purgeRevisions();
      expect(await service.owner.revisionsFor(item.id), isEmpty);
      expect(store.revisionPurgeFacts.single.version, 1);
      expect(
        service.owner.information.single.fields.single.value,
        'CURRENT-SECRET-94815',
      );
      await service.close();
      await store.close();
      now = DateTime.utc(2026, 10, 2);
      store = await EncryptedInformationRepository.open(folder.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store, clock: () => now);
      addTearDown(service.close);
      expect(await service.owner.revisionsFor(item.id), isEmpty);
      expect(store.revisionPurgeFacts.single.version, 1);
      for (final file in folder.listSync().whereType<File>()) {
        if (file.path.endsWith('.lock')) continue;
        expect(
          String.fromCharCodes(await file.readAsBytes()),
          isNot(contains('SECRET-94815')),
        );
      }
    },
  );
}
