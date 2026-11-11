@TestOn('windows')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_storage/info_storage.dart';

void main() {
  test(
    'Windows local library protects its real DPAPI key, reopens and preserves data when the key is missing',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'chiyo-win-local-',
      );
      final root = Directory(await temporary.resolveSymbolicLinks());
      DesktopLibrary? opened;
      try {
        final configuration = await LocalLibraryConfiguration.open(root.path);
        opened = await openLocalLibrary(configuration);
        final item = await opened.service.owner.createInformation(
          'Windows local fixture',
          '',
          [const FieldInput('Body', '', 'SYNTHETIC_WINDOWS_LOCAL_CONTENT')],
        );
        final key = File(
          '${configuration.libraryDirectory}/database-key.dpapi',
        );
        WindowsPrivateFiles.verify(key.path);
        await opened.service.close();
        await opened.close();
        opened = null;
        final encrypted = File(
          '${configuration.libraryDirectory}/library.db',
        ).readAsBytesSync();
        expect(
          String.fromCharCodes(
            encrypted,
          ).contains('SYNTHETIC_WINDOWS_LOCAL_CONTENT'),
          isFalse,
        );
        opened = await openLocalLibrary(configuration);
        expect(opened.service.owner.information.single.id, item.id);
        await opened.service.close();
        await opened.close();
        opened = null;
        final original = await key.rename('${key.path}.retained');
        final beforeMissingKey = File(
          '${configuration.libraryDirectory}/library.db',
        ).readAsBytesSync();
        try {
          await expectLater(
            openLocalLibrary(configuration),
            throwsA(isA<StorageFailure>()),
          );
          expect(await key.exists(), isFalse);
          expect(
            File(
              '${configuration.libraryDirectory}/library.db',
            ).readAsBytesSync(),
            beforeMissingKey,
          );
        } finally {
          await original.rename(key.path);
        }
        opened = await openLocalLibrary(configuration);
        expect(opened.service.owner.information.single.id, item.id);
      } finally {
        if (opened != null) {
          await opened.service.close();
          await opened.close();
        }
        await root.delete(recursive: true);
      }
    },
  );
}
