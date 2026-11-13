import 'dart:io';
import 'package:info_cli/installed_ego_browser.dart';
import 'package:test/test.dart';

void main() {
  test(
    'internal discovery ignores relative PATH and resolves only an installed executable',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-ego-location-');
      addTearDown(() => root.delete(recursive: true));
      final bin = await Directory('${root.path}/bin').create();
      final name = Platform.isWindows ? 'ego-browser.exe' : 'ego-browser';
      expect(
        await findInstalledEgoBrowser(environment: {'PATH': 'relative'}),
        null,
      );
      final file = await File(
        '${bin.path}/$name',
      ).writeAsString('SYNTHETIC-NOT-EXECUTED');
      if (!Platform.isWindows) {
        await Process.run('/bin/chmod', ['600', file.path]);
        expect(
          await findInstalledEgoBrowser(environment: {'PATH': bin.path}),
          null,
        );
        await Process.run('/bin/chmod', ['700', file.path]);
      }
      expect(
        await findInstalledEgoBrowser(environment: {'PATH': bin.path}),
        await file.resolveSymbolicLinks(),
      );
    },
  );
  test(
    'Mac App container home resolves the existing user helper without reading profiles',
    () async {
      if (!Platform.isMacOS) return;
      final home = await Directory.systemTemp.createTemp('chiyo-ego-home-');
      addTearDown(() => home.delete(recursive: true));
      final file = await File(
        '${home.path}/.local/bin/ego-browser',
      ).create(recursive: true);
      await file.writeAsString('SYNTHETIC-NOT-EXECUTED');
      await Process.run('/bin/chmod', ['700', file.path]);
      final selected = await findInstalledEgoBrowser(
        environment: {
          'HOME':
              '${home.path}/Library/Containers/com.example.infoDesktop/Data',
          'PATH': '',
        },
      );
      expect(selected, await file.resolveSymbolicLinks());
    },
  );
}
