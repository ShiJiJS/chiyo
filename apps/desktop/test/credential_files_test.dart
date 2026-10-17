import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/credential_files.dart';

void main() {
  test(
    'file import owns opaque bytes, keeps only basename, and refuses empty or oversized input',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'credential-file-import-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final source = File('${folder.path}/synthetic.key');
      await source.writeAsBytes([0, 255, 1, 254], flush: true);
      final imported = await readCredentialFile(source.path);
      await source.writeAsBytes([42], flush: true);
      expect(imported.name, 'synthetic.key');
      expect(imported.bytes, [0, 255, 1, 254]);
      await source.writeAsBytes([], flush: true);
      await expectLater(readCredentialFile(source.path), throwsFormatException);
      await source.writeAsBytes(List.filled(1048577, 1), flush: true);
      await expectLater(readCredentialFile(source.path), throwsFormatException);
      await source.writeAsBytes(List.filled(1048576, 1), flush: true);
      expect((await readCredentialFile(source.path)).bytes.length, 1048576);
    },
  );
}
