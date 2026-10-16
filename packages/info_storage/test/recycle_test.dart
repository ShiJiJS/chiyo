import 'dart:io';
import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'current-data backup restores metadata retained after deleting the last field',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'info-recycle-backup-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${folder.path}/source',
        TestKeyStore(),
      );
      final service = InformationService(repository: source);
      addTearDown(() async {
        await service.close();
        await source.close();
      });
      final item = await service.owner.createInformation(
        'retained metadata',
        'public description',
        [const FieldInput('host', '', 'private.invalid')],
      );
      await service.owner.deleteInformation(
        item.id,
        1,
        fieldId: item.fields.single.id,
      );
      final recovery = await source.backups.enable();
      final backup = '${folder.path}/empty-fields.aimbackup';
      await source.backups.exportTo(backup);
      await service.close();
      await source.close();
      final recipient = await EncryptedInformationRepository.open(
        '${folder.path}/recipient',
        TestKeyStore(),
      );
      addTearDown(recipient.close);
      await recipient.backups.restoreFrom(backup, recovery);
      expect(recipient.items.single.name, 'retained metadata');
      expect(recipient.items.single.version, 2);
      expect(recipient.items.single.fields, isEmpty);
    },
  );
  test(
    'development schema eight migrates and terminal import payloads are scrubbed without losing receipt or pending work',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'info-recycle-migration-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      final initial = await EncryptedInformationRepository.open(
        folder.path,
        keys,
      );
      await initial.close();
      final fixture = sqlite3.open('${folder.path}/library.db');
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      fixture.execute('PRAGMA key = "x\'$hex\'"');
      fixture.execute('DROP TABLE recycle_entries');
      fixture.execute('DROP TABLE recycle_facts');
      fixture.execute('DROP TABLE delete_proposals');
      fixture.execute('PRAGMA user_version = 8');
      for (final state in ['confirmed', 'rejected', 'pending']) {
        final payload = {
          'id': state,
          'sessionBinding': 'non-secret-correlation',
          'chatLabel': 'old chat',
          'createdAt': '2026-10-16T00:00:00.000Z',
          'version': state == 'pending' ? 1 : 2,
          'state': state,
          'createdItemIds': state == 'confirmed' ? ['past-item'] : <String>[],
          'items': [
            {
              'name': 'old',
              'description': '',
              'fields': [
                {
                  'name': 'secret',
                  'description': '',
                  'value': 'LEGACY-SECRET',
                  'kind': 'structured',
                },
              ],
            },
          ],
        };
        fixture.execute(
          'INSERT INTO import_proposals(id,payload) VALUES(?,?)',
          [state, jsonEncode(payload)],
        );
      }
      fixture.close();
      final store = await EncryptedInformationRepository.open(
        folder.path,
        keys,
      );
      final service = InformationService(repository: store);
      addTearDown(() async {
        await service.close();
        await store.close();
      });
      for (final p in service.owner.importProposals.where(
        (p) => p.state != ImportProposalState.pending,
      )) {
        expect(p.toJson().toString(), isNot(contains('LEGACY-SECRET')));
        expect(p.itemCount, 1);
      }
      expect(
        service.owner.importProposals.last.items.single.fields.single.value,
        'LEGACY-SECRET',
      );
      final receipt = (await service.owner.confirmImport(
        'confirmed',
        1,
        const [],
      )).single;
      expect(receipt.id, 'past-item');
      expect(receipt.version, 1);
      expect(service.owner.information, isEmpty);
      final item = await service.owner.createInformation('after upgrade', '', [
        const FieldInput('host', '', 'new.invalid'),
      ]);
      expect(
        (await service.owner.deleteInformation(item.id, 1)).snapshot!.id,
        item.id,
      );
    },
  );
  test(
    'deleted content and facts survive encrypted reopen then restore with monotonic identity and purge',
    () async {
      final folder = await Directory.systemTemp.createTemp('info-recycle-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var now = DateTime.utc(2026, 10, 16);
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store, clock: () => now);
      final item = await service.owner.createInformation('fictional', '', [
        const FieldInput('private', '', 'RECYCLE-SECRET-723862'),
      ]);
      final session = service.agent.openSession('agent');
      final id = await service.agent.submitDelete(session, item.id, 1);
      await service.owner.confirmDelete(id, 1);
      await Future.sync(service.close);
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store, clock: () => now);
      expect(service.agent.catalog(), isEmpty);
      final entry = service.owner.recycleEntries.single;
      expect(entry.snapshot!.fields.single.value, 'RECYCLE-SECRET-723862');
      final restored = await service.owner.restoreRecycled(entry.id);
      expect(restored.id, item.id);
      expect(restored.version, 3);
      await service.owner.deleteInformation(item.id, 3);
      now = now.add(const Duration(days: 30));
      await service.owner.purgeRecycle();
      await Future.sync(service.close);
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(
        repository: store,
        clock: () => now.subtract(const Duration(days: 1)),
      );
      addTearDown(() async {
        await Future.sync(service.close);
        await store.close();
      });
      expect(service.owner.recycleEntries, isEmpty);
      expect(service.owner.recycleFacts.map((f) => f.kind), [
        RecycleFactKind.deleted,
        RecycleFactKind.restored,
        RecycleFactKind.deleted,
        RecycleFactKind.purged,
      ]);
      expect(store.recycleEntries.every((e) => e.snapshot == null), isTrue);
      for (final file in folder.listSync().whereType<File>()) {
        if (file.path.endsWith('.lock')) continue;
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('RECYCLE-SECRET-723862')),
        );
      }
    },
  );
}
