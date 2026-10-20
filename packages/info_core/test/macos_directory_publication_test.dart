@TestOn('mac-os')
library;

import 'dart:io';
import 'package:info_core/new_file_publish.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prepared directory publishes atomically and cannot replace a raced empty directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mac-directory-publish-',
      );
      addTearDown(() => root.delete(recursive: true));
      final prepared = await Directory('${root.path}/prepared').create();
      await File('${prepared.path}/ready').writeAsString('synthetic complete');
      final target = Directory('${root.path}/中文 目标');
      expect(await target.exists(), isFalse);
      // A competing actor creates a destination after the preflight check.
      await target.create();
      expect(
        () => publishNewDirectory(prepared.path, target.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.list().isEmpty, isTrue);
      expect(
        await File('${prepared.path}/ready').readAsString(),
        'synthetic complete',
      );
      await target.delete();
      publishNewDirectory(prepared.path, target.path);
      expect(await prepared.exists(), isFalse);
      expect(
        await File('${target.path}/ready').readAsString(),
        'synthetic complete',
      );
    },
  );
}
