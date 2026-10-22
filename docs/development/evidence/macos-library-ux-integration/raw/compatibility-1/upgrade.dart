import 'dart:io';
import 'dart:convert';
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

class SyntheticKeys implements DatabaseKeyStore {
  SyntheticKeys(this.value);
  final int value;
  @override
  Future<List<int>?> read() async => List.filled(32, value);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Test key exists');
}

DatabaseKeyStore keys(String root, String name) =>
    SyntheticKeys(name == 'source' ? 158 : 159);

int schema(String root, List<int> key) {
  final db = sql.sqlite3.open('$root/source/library.db');
  try {
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute('PRAGMA key = "x\'' + hex + '\'"');
    return db.select('PRAGMA user_version').single.values.single as int;
  } finally {
    db.close();
  }
}

Future<void> main(List<String> args) async {
  final root = args.single, k = keys(args.single, 'source');
  final id = jsonDecode(await File('$root/identity.json').readAsString());
  final recovery = (await File('$root/recovery.txt').readAsString()).trim();
  if (schema(root, (await k.read())!) != 21)
    throw StateError('Not an actual old fixture');
  final repo = await EncryptedInformationRepository.open('$root/source', k);
  final service = InformationService(repository: repo);
  try {
    final o = service.owner, i = service.owner.information.single;
    if (i.id != id['id'] ||
        i.fields.single.id != id['field'] ||
        i.fields.single.value != 'synthetic content')
      throw StateError('Migration changed identity or content');
    final old = await repo.backups.inspect('$root/old.aimbackup', recovery);
    if (old.formatVersion > 9 || old.informationCount != 1)
      throw StateError('Old backup not readable');
    await o.deleteTag(o.tags.single.id, o.tags.single.version);
    await o.deleteInformation(i.id, o.information.single.version);
    await o.deleteDirectory(
      o.directories.single.id,
      o.directories.single.version,
    );
    await o.exportLibrary(() => repo.backups.exportTo('$root/new.aimbackup'));
    final current = await repo.backups.inspect('$root/new.aimbackup', recovery);
    if (current.formatVersion != 10)
      throw StateError('Expected conditional format10');
  } finally {
    await service.close();
    await repo.close();
  }
  if (schema(root, (await k.read())!) != 22)
    throw StateError('Migration did not mark schema22');
  final recipient = await EncryptedInformationRepository.open(
    '$root/old-restore',
    keys(root, 'old-restore'),
  );
  try {
    final contents = await recipient.backups.inspect(
      '$root/old.aimbackup',
      recovery,
    );
    await recipient.backups.restore(contents);
    if (recipient.items.single.id != id['id'])
      throw StateError('Old backup lost identity');
  } finally {
    await recipient.close();
  }
  stdout.writeln('SCHEMA21_TO22_IDENTITY_AND_OLD_BACKUP_RESTORE_PASSED');
}
