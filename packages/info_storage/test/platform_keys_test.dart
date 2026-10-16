import 'dart:io';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
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
