import 'dart:io';
import 'package:info_core/new_file_publish.dart';
import 'package:test/test.dart';

void main() {
  test(
    'publishes without replacing a file, symlink or empty directory',
    () async {
      final root = await Directory.systemTemp.createTemp('publish-exclusive-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/source');
      final target = File('${root.path}/target');
      await source.writeAsString('prepared');
      publishNewFile(source.path, target.path);
      expect(await target.readAsString(), 'prepared');
      expect(await source.exists(), isFalse);
      await source.writeAsString('new');
      expect(
        () => publishNewFile(source.path, target.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), 'prepared');
      expect(await source.readAsString(), 'new');
      final link = Link('${root.path}/link');
      await link.create(target.path);
      expect(
        () => publishNewFile(source.path, link.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), 'prepared');
      final from = await Directory('${root.path}/from').create();
      final to = await Directory('${root.path}/to').create();
      expect(
        () => publishNewDirectory(from.path, to.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await from.exists(), isTrue);
      expect(await to.exists(), isTrue);
      final published = '${root.path}/published';
      publishNewDirectory(from.path, published);
      expect(await Directory(published).exists(), isTrue);
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}
