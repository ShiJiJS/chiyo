import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
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
