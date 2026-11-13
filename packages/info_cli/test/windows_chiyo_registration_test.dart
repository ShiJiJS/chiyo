@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/codex_registration.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, bundle;
  late File descriptor;
  const required = [
    'chiyo.exe',
    'info-codex.exe',
    'info-codex-hook.exe',
    'info-runtime-worker.exe',
  ];

  setUp(() async {
    final base = Directory('../../build/wreg').absolute;
    await base.create(recursive: true);
    root = await Directory(
      await base.resolveSymbolicLinks(),
    ).createTemp('登记 QA ');
    bundle = await Directory(
      '${root.path}/安装 空格/current/cli',
    ).create(recursive: true);
    for (final name in required) {
      await File(
        '${bundle.path}/$name',
      ).writeAsString('Synthetic non-executable $name');
    }
    await Directory('${bundle.path}/template').create();
    await File(
      '${bundle.path}/template/SKILL.md',
    ).writeAsString('Synthetic package instructions.');
    descriptor = File('${root.path}/public descriptor/integration.json');
  });
  tearDown(() async {
    final base = Directory('../../build/wreg').absolute;
    final resolved = await root.resolveSymbolicLinks();
    if (!resolved.startsWith('${await base.resolveSymbolicLinks()}\\')) {
      throw StateError('Registration fixture escaped its build directory');
    }
    await root.delete(recursive: true);
  });

  void expectUnified(Map<String, Object?> value) {
    expect(value['schemaVersion'], 2);
    expect(
      (value['cliPath'] as String).replaceAll('\\', '/'),
      endsWith('/cli/chiyo.exe'),
    );
    expect(
      (value['hookPath'] as String).replaceAll('\\', '/'),
      endsWith('/cli/info-codex-hook.exe'),
    );
    expect(
      (value['workerPath'] as String).replaceAll('\\', '/'),
      endsWith('/cli/info-runtime-worker.exe'),
    );
    final paths = (value['files'] as List).map((row) => (row as Map)['path']);
    expect(paths, containsAll(required));
    final serialized = jsonEncode(value);
    for (final privateField in [
      'sessionSecret',
      'association',
      'CHIYO_CONTEXT',
    ]) {
      expect(serialized, isNot(contains(privateField)));
    }
  }

  test(
    'Windows public registration selects chiyo and can repeat atomically',
    () async {
      final first = await registerCodexRuntime(bundle, descriptor: descriptor);
      expectUnified(first);
      final row = (first['files'] as List).cast<Map>().singleWhere(
        (row) => row['path'] == 'chiyo.exe',
      );
      final bytes = await File('${bundle.path}/chiyo.exe').readAsBytes();
      expect(row['sha256'], sha256.convert(bytes).toString());
      final second = await registerCodexRuntime(bundle, descriptor: descriptor);
      expectUnified(second);
      expect(jsonDecode(await descriptor.readAsString()), second);
      for (final name in required) {
        expect(
          await File('${bundle.path}/$name').readAsString(),
          'Synthetic non-executable $name',
        );
      }
    },
  );

  test(
    'a schema1 descriptor upgrades while legacy binaries keep their role',
    () async {
      await descriptor.parent.create();
      await descriptor.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'bundleDirectory': bundle.path,
          'cliPath': '${bundle.path}/info-codex.exe',
          'hookPath': '${bundle.path}/info-codex-hook.exe',
          'workerPath': '${bundle.path}/info-runtime-worker.exe',
          'skillPath': '${bundle.path}/template/SKILL.md',
          'files': [
            for (final name in required.where((name) => name != 'chiyo.exe'))
              {
                'path': name,
                'bytes': await File('${bundle.path}/$name').length(),
                'sha256': sha256
                    .convert(await File('${bundle.path}/$name').readAsBytes())
                    .toString(),
              },
          ],
        }),
      );
      final value = await registerCodexRuntime(bundle, descriptor: descriptor);
      expectUnified(value);
      expect(jsonDecode(await descriptor.readAsString()), value);
    },
  );

  test(
    'a missing unified binary cannot replace an existing registration',
    () async {
      await descriptor.parent.create();
      final original = utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'cliPath': '${bundle.path}/info-codex.exe',
          'files': <Object>[],
        }),
      );
      await descriptor.writeAsBytes(original);
      await File('${bundle.path}/chiyo.exe').delete();
      await expectLater(
        registerCodexRuntime(bundle, descriptor: descriptor),
        throwsA(isA<FormatException>()),
      );
      expect(await descriptor.readAsBytes(), original);
    },
  );
}
