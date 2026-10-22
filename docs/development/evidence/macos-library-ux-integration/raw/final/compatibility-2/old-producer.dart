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
  final repo = await EncryptedInformationRepository.open('$root/source', k);
  final service = InformationService(repository: repo);
  try {
    final o = service.owner,
        d = await service.owner.createDirectory('Project'),
        t = await service.owner.createTag('Docs');
    final i = await o.createInformation(
      'Synthetic resume',
      '',
      [const FieldInput('Text', '', 'synthetic content')],
      directoryId: d.id,
      tagIds: [t.id],
    );
    await File('$root/identity.json').writeAsString(
      jsonEncode({
        'id': i.id,
        'field': i.fields.single.id,
        'directory': d.id,
        'tag': t.id,
      }),
    );
    await repo.backups.enable();
    await repo.backups.saveRecoveryKeyTo('$root/recovery.txt');
    await o.exportLibrary(() => repo.backups.exportTo('$root/old.aimbackup'));
  } finally {
    await service.close();
    await repo.close();
  }
  if (schema(root, (await k.read())!) != 21)
    throw StateError('Old source did not create schema21');
  stdout.writeln('UNCHANGED_OLD_READER_CREATED_SCHEMA21');
}
