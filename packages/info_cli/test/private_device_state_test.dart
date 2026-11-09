import 'dart:io';
import 'package:info_cli/private_device_state.dart';
import 'package:test/test.dart';

void main() {
  test(
    'concurrent first callers create one private regular lock file; links remain rejected',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'private-device-lock-race-',
      );
      try {
        final folder = await privateDeviceDirectory(root);
        final lock = File('${folder.path}/shared.launch');
        await Future.wait(List.generate(32, (_) => privateDeviceFile(lock)));
        expect(
          await FileSystemEntity.type(lock.path, followLinks: false),
          FileSystemEntityType.file,
        );
        expect((await lock.stat()).mode & 0xE3F, 0);
        final target = File('${folder.path}/target');
        await target.writeAsString('SYNTHETIC_UNCHANGED');
        final link = Link('${folder.path}/not-a-lock');
        await link.create(target.path);
        await expectLater(
          privateDeviceFile(File(link.path)),
          throwsA(anything),
        );
        expect(await target.readAsString(), 'SYNTHETIC_UNCHANGED');
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
