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
  final root = args.single;
  var refused = false;
  try {
    final unexpected = await EncryptedInformationRepository.open(
      '$root/source',
      keys(root, 'source'),
    );
    await unexpected.close();
  } on StorageFailure catch (e) {
    refused = e.code == 'unsupported_schema';
  }
  if (!refused) throw StateError('Old application accepted schema22');
  final recipient = await EncryptedInformationRepository.open(
    '$root/old-reader',
    keys(root, 'old-reader'),
  );
  try {
    var denied = false;
    final recovery = (await File('$root/recovery.txt').readAsString()).trim();
    try {
      await recipient.backups.inspect('$root/new.aimbackup', recovery);
    } on StorageFailure catch (e) {
      denied = e.code == 'unsupported_backup';
    }
    if (!denied || recipient.items.isNotEmpty)
      throw StateError('Old reader accepted format10 or modified recipient');
  } finally {
    await recipient.close();
  }
  if (schema(root, (await keys(root, 'source').read())!) != 22)
    throw StateError('Old reader changed schema marker');
  stdout.writeln('UNCHANGED_OLD_READER_REJECTED_SCHEMA22_AND_FORMAT10');
}
