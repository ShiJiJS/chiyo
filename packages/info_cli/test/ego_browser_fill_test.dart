import 'dart:convert';
import 'dart:io';
import 'package:info_cli/ego_browser_fill.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String executable;
  late EgoBrowserFill driver;
  const material = '  Synthetic-示例😊-quoted  ';
  final target = BrowserFormTarget.fromJson({
    'provider': 'ego',
    'space': 1,
    'pageId': 'p1',
    'url': 'http://localhost/login',
    'form': '#login',
    'field': '#password',
    'instanceId': 'a' * 64,
    'structureDigest': '0' * 64,
  });
  Future<void> mode(String value) => File(
    '${root.path}/mode.json',
  ).writeAsString(jsonEncode({'mode': value, 'password': material}));

  setUpAll(() async {
    final base = Directory('../../build/ego-fill-transport').absolute;
    await base.create(recursive: true);
    root = await base.createTemp('helper-');
    executable = '${root.path}/ego-helper${Platform.isWindows ? '.exe' : ''}';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/support/ego_helper_fixture.dart',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: 'Synthetic helper must compile');
    driver = EgoBrowserFill(executable);
  });
  tearDownAll(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  test(
    'same installed-helper seam inspects and passes material only over stdin',
    () async {
      await mode('ready');
      final inspected = await driver.inspect(
        space: 1,
        page: 'p1',
        url: target.url,
        form: '#login',
        field: '#password',
      );
      expect(inspected.target.instanceId, 'a' * 64);
      expect(inspected.target.structureDigest, hasLength(64));
      await mode('filled');
      expect(await driver.fill(target, material), {'status': 'filled'});
      final observed = jsonDecode(
        await File('${root.path}/observed.json').readAsString(),
      );
      expect(observed, {
        'args': ['nodejs'],
        'argvContainsMaterial': false,
        'environmentContainsMaterial': false,
        'stdinContainsMaterial': true,
      });
    },
  );
  for (final failure in [
    'echo',
    'duplicate',
    'malformed',
    'excessive',
    'timeout',
  ]) {
    test(
      '$failure after helper start is unknown and never echoes source/material',
      () async {
        await mode(failure);
        final candidate = EgoBrowserFill(
          executable,
          timeout: const Duration(milliseconds: 700),
        );
        final receipt = await candidate.fill(target, material);
        expect(receipt['status'], 'unknown');
        expect(jsonEncode(receipt), isNot(contains(material)));
        if (failure == 'timeout') expect(receipt['code'], 'browser_timeout');
      },
    );
  }
  test('untrusted error code and extra receipt fields are dropped', () async {
    await mode('invalid-code');
    expect(await driver.fill(target, material), {
      'status': 'refused',
      'code': 'browser_operation_failed',
    });
  });
  test(
    'missing helper is refused before dispatch; invalid values do not start it',
    () async {
      final absent = EgoBrowserFill('${root.path}/absent.exe');
      expect(await absent.fill(target, material), {
        'status': 'refused',
        'code': 'browser_unavailable',
      });
      for (final value in ['', 'line\nbreak', '\x00', 'x' * 65537]) {
        expect(await absent.fill(target, value), {
          'status': 'refused',
          'code': 'unsupported_password_value',
        });
      }
    },
  );
}
