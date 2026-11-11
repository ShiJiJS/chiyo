import 'dart:io';
import 'dart:typed_data';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Mac local keys use the exact library identity and only request interaction explicitly',
    () async {
      final calls = <(String, Object?)>[];
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      Future<Object?> invoke(String method, Object? args) async {
        calls.add((method, args));
        return method.startsWith('read') ? key : null;
      }

      const id = 'abcdefghijklmnopqrstuvwx12345678';
      final silent = MacOsDatabaseKeyStore.forLibrary(id, invoke);
      expect(await silent.read(), key);
      await silent.create(key);
      final interactive = MacOsDatabaseKeyStore.forLibrary(
        id,
        invoke,
        requestKeyAccess: true,
      );
      expect(await interactive.read(), key);
      expect(calls.map((c) => c.$1), [
        'readLocal',
        'createLocal',
        'readLocalWithInteraction',
      ]);
      expect(calls[0].$2, {'libraryId': id});
      expect(calls[1].$2, {'libraryId': id, 'key': key});
      expect(calls[2].$2, {'libraryId': id});
      expect(
        () => MacOsDatabaseKeyStore.forLibrary('../another-library', invoke),
        throwsA(isA<StorageFailure>()),
      );
      expect(calls, hasLength(3));
    },
  );
  test(
    'Windows profile protection reopens and refuses replacement or tamper',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'info-dpapi-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/test-key.dpapi';
      final key = List.generate(32, (i) => i);
      final keys = WindowsDatabaseKeyStore(path);
      expect(await keys.read(), isNull);
      await keys.create(key);
      expect(await WindowsDatabaseKeyStore(path).read(), key);
      await expectLater(
        keys.create(List.filled(32, 42)),
        throwsA(isA<StorageFailure>()),
      );
      final file = File(path);
      final bytes = await file.readAsBytes();
      bytes[bytes.length ~/ 2] ^= 1;
      await file.writeAsBytes(bytes);
      await expectLater(keys.read(), throwsA(isA<StorageFailure>()));
    },
    skip: !Platform.isWindows,
  );
}
