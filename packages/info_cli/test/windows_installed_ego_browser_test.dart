@TestOn('windows')
library;

import 'dart:io';
import 'package:info_cli/installed_ego_browser.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    final base = Directory('../../build/windows-ego-discovery').absolute;
    await base.create(recursive: true);
    root = await Directory(
      await base.resolveSymbolicLinks(),
    ).createTemp('安装 空格 ');
  });
  tearDown(() async {
    final base = await Directory(
      '../../build/windows-ego-discovery',
    ).resolveSymbolicLinks();
    if (!(await root.resolveSymbolicLinks()).startsWith('$base\\')) {
      throw StateError('Ego fixture escaped build root');
    }
    await root.delete(recursive: true);
  });
  Future<File> helper(String version) async {
    final file = File(
      '${root.path}/Program Files/Citro Labs/ego lite/Application/$version/ego-browser.exe',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('SYNTHETIC-NEVER-EXECUTED');
    return file;
  }

  test(
    'desktop environment with no helper PATH resolves the newest installed version numerically',
    () async {
      await helper('0.6.3.9');
      final newest = await helper('0.6.3.14');
      await helper('0.6.2.100');
      await Directory('${newest.parent.parent.path}/SetupMetrics').create();
      final selected = await findInstalledEgoBrowser(
        environment: {
          'PATH': '${root.path}/removed/0.6.2.7',
          'PROGRAMFILES': '${root.path}/Program Files',
        },
      );
      expect(selected, await newest.resolveSymbolicLinks());
    },
  );
  test(
    'an explicit existing helper PATH remains preferred to installation fallback',
    () async {
      await helper('0.6.3.14');
      final direct = await File(
        '${root.path}/explicit/ego-browser.exe',
      ).create(recursive: true);
      await direct.writeAsString('SYNTHETIC-NEVER-EXECUTED');
      expect(
        await findInstalledEgoBrowser(
          environment: {
            'PATH': direct.parent.path,
            'ProgramW6432': '${root.path}/Program Files',
          },
        ),
        await direct.resolveSymbolicLinks(),
      );
    },
  );
  test(
    'missing helper, malformed version and relative installation roots are ignored',
    () async {
      final old = await helper('0.6.3.9');
      await Directory('${old.parent.parent.path}/0.6.3.99').create();
      await helper('not-a-version');
      expect(
        await findInstalledEgoBrowser(
          environment: {
            'Path': 'relative',
            'ProgramFiles': '${root.path}/Program Files',
          },
        ),
        await old.resolveSymbolicLinks(),
      );
      expect(
        await findInstalledEgoBrowser(
          environment: {'PATH': '', 'ProgramFiles': 'relative'},
        ),
        null,
      );
      expect(
        await findInstalledEgoBrowser(
          environment: {
            'PATH': '',
            'LOCALAPPDATA': root.path,
            'HOME': root.path,
          },
        ),
        null,
      );
    },
  );
}
