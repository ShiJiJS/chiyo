import 'dart:io';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File key;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chiyo-server-key-');
    key = File('${root.path}/database.key');
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> writeKey({int length = 32, String mode = '600'}) async {
    await key.writeAsBytes(List.generate(length, (i) => i));
    final result = await Process.run('chmod', [mode, key.path]);
    expect(result.exitCode, 0);
  }

  test('reads a provisioned private key without modifying it', () async {
    await writeKey();
    final store = MountedDatabaseKeyStore(key.path);
    expect(await store.read(), List.generate(32, (i) => i));
    await expectLater(
      store.create(List.filled(32, 7)),
      throwsA(isA<StorageFailure>()),
    );
    expect(await key.readAsBytes(), List.generate(32, (i) => i));
  });

  test('missing key cannot create a library or a replacement secret', () async {
    final data = '${root.path}/data';
    await expectLater(
      EncryptedInformationRepository.open(
        data,
        MountedDatabaseKeyStore(key.path),
      ),
      throwsA(isA<StorageFailure>()),
    );
    expect(await key.exists(), isFalse);
    expect(await File('$data/library.db').exists(), isFalse);
  });

  test(
    'refuses a symlink, malformed secret and group readable secret',
    () async {
      await writeKey();
      final link = Link('${root.path}/linked.key');
      await link.create(key.path);
      await expectLater(
        MountedDatabaseKeyStore(link.path).read(),
        throwsA(isA<StorageFailure>()),
      );
      await writeKey(length: 31);
      await expectLater(
        MountedDatabaseKeyStore(key.path).read(),
        throwsA(isA<StorageFailure>()),
      );
      await writeKey(mode: '640');
      await expectLater(
        MountedDatabaseKeyStore(key.path).read(),
        throwsA(isA<StorageFailure>()),
      );
    },
  );
}
