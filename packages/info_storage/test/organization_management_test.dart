import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'backup_setup.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

void main() {
  test(
    'encrypted removal rolls back on storage failure and format10 preserves detached history',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'organization-removal-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = _Keys();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      addTearDown(() async {
        await service.close();
        await store.close();
      });
      final o = service.owner;
      final dir = await o.createDirectory('Project');
      final tag = await o.createTag('Docs');
      final item = await o.createInformation(
        'Resume',
        '',
        [const FieldInput('Text', '', 'fictional resume')],
        directoryId: dir.id,
        tagIds: [tag.id],
      );
      final db = sqlite3.open('${folder.path}/library.db');
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute(
        "CREATE TRIGGER deny_tag_delete BEFORE DELETE ON information_tags BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        o.deleteTag(tag.id, tag.version),
        throwsA(isA<StorageFailure>()),
      );
      expect(o.tags.single.id, tag.id);
      expect(o.information.single.version, item.version);
      expect(o.information.single.tagIds, [tag.id]);
      expect(await o.revisionsFor(item.id), isEmpty);
      db.execute('DROP TRIGGER deny_tag_delete');
      db.close();
      await o.deleteTag(tag.id, tag.version);
      final recycled = await o.deleteInformation(
        item.id,
        o.information.single.version,
      );
      await o.deleteDirectory(dir.id, dir.version);
      final recovery = await enableTestBackups(store.backups);
      await store.backups.exportTo('${folder.path}/removed.aimbackup');
      final snapshot = await store.backups.inspect(
        '${folder.path}/removed.aimbackup',
        recovery,
      );
      expect(snapshot.formatVersion, 10);
      expect(snapshot.directoryCount, 0);
      expect(snapshot.tagCount, 0);
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      expect(service.owner.tags, isEmpty);
      expect(service.owner.directories, isEmpty);
      await service.owner.restoreRecycled(recycled.id);
      expect(service.owner.information.single.directoryId, isNull);
      expect(service.owner.information.single.tagIds, isEmpty);
      expect(
        service.owner.information.single.fields.single.value,
        'fictional resume',
      );
      await service.close();
      await store.close();
      final recipient = await EncryptedInformationRepository.open(
        '${folder.path}/recipient',
        _Keys(),
      );
      final contents = await recipient.backups.inspect(
        '${folder.path}/removed.aimbackup',
        recovery,
      );
      await recipient.backups.restore(contents);
      final restoredService = InformationService(repository: recipient);
      await restoredService.owner.restoreRecycled(recycled.id);
      expect(restoredService.owner.information.single.directoryId, isNull);
      expect(
        restoredService.owner.information.single.fields.single.value,
        'fictional resume',
      );
      expect(
        restoredService.owner.informationRevisions.any(
          (r) => r.item.tagIds.contains(tag.id),
        ),
        isTrue,
      );
      await restoredService.close();
      await recipient.close();
    },
  );
}
