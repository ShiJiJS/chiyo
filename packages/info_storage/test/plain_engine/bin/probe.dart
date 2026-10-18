import 'dart:io';
import 'package:info_storage/info_storage.dart';

class TestKeys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async {
    value = key;
  }
}

Future<void> main() async {
  final folder = await Directory.systemTemp.createTemp('plain-engine-probe-');
  try {
    var rejected = false;
    try {
      final store = await EncryptedInformationRepository.open(
        folder.path,
        TestKeys(),
      );
      await store.close();
    } on StorageFailure catch (error) {
      rejected = error.code == 'cipher_unavailable';
    }
    if (!rejected || await File('${folder.path}/library.db').exists()) {
      throw StateError(
        'Plain SQLite was not rejected before creating a database',
      );
    }
    stdout.writeln('PASS: plain SQLite rejected without creating database');
  } finally {
    await folder.delete(recursive: true);
  }
}
