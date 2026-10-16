import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';

/// Run the compiled release executable, never the desktop, using synthetic data
/// and an isolated current-user DPAPI envelope. Prints only non-sensitive results.
Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Windows DPAPI smoke only');
  final directory = await Directory.systemTemp.createTemp(
    'info-release-smoke-',
  );
  EncryptedInformationRepository? repository;
  try {
    final keys = WindowsDatabaseKeyStore('${directory.path}/smoke.dpapi');
    repository = await EncryptedInformationRepository.open(
      directory.path,
      keys,
    );
    var service = InformationService(repository: repository);
    final item = await service.owner.createInformation(
      'Fictional smoke',
      'Public',
      [const FieldInput('Notes', 'Private', 'FICTIONAL-RELEASE-MARKER-13869')],
    );
    final ref = FieldRef(item.id, item.fields.single.id);
    final session = service.agent.openSession('release smoke');
    final request = service.agent.request(session, 'test', [ref]);
    service.owner.approve(request.id, [ref]);
    final token = service.agent.claim(session, request.id).token;
    final version = repository.cipherVersion;
    service.close();
    await repository.close();
    repository = await EncryptedInformationRepository.open(
      directory.path,
      keys,
    );
    service = InformationService(repository: repository);
    if (service.owner.information.single.fields.single.value !=
        'FICTIONAL-RELEASE-MARKER-13869')
      throw StateError('Reopen failed');
    var denied = false;
    try {
      service.agent.read(token, ref);
    } on AccessFailure {
      denied = true;
    }
    if (!denied) throw StateError('Old token survived');
    await repository.close();
    for (final file in directory.listSync().whereType<File>()) {
      if (String.fromCharCodes(
        file.readAsBytesSync(),
      ).contains('FICTIONAL-RELEASE-MARKER-13869'))
        throw StateError('Plaintext marker found');
    }
    // Build a prior-schema encrypted fixture using this same protected key.
    final migrationDirectory = await Directory(
      '${directory.path}/migration',
    ).create();
    final migrationKeys = WindowsDatabaseKeyStore(
      '${migrationDirectory.path}/smoke.dpapi',
    );
    await migrationKeys.create((await keys.read())!);
    final key = (await migrationKeys.read())!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final fixture = sqlite3.open('${migrationDirectory.path}/library.db');
    fixture.execute('PRAGMA key = "x\'$key\'"');
    fixture.execute(
      'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL)',
    );
    fixture.execute(
      'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL,name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL)',
    );
    fixture.execute('PRAGMA user_version = 1');
    fixture.close();
    repository = await EncryptedInformationRepository.open(
      migrationDirectory.path,
      migrationKeys,
    );
    await InformationService(repository: repository).owner.createInformation(
      'Migrated',
      '',
      [const FieldInput('Notes', '', 'fictional')],
    );
    await repository.close();
    repository = await EncryptedInformationRepository.open(
      migrationDirectory.path,
      migrationKeys,
    );
    if (repository.items.single.version != 1)
      throw StateError('Migration failed');
    stdout.writeln(
      'PASS: SQLCipher $version; current-user DPAPI, encrypted reopen, token invalidation, plaintext scan, schema migration',
    );
  } finally {
    await repository?.close();
    await directory.delete(recursive: true);
  }
}
