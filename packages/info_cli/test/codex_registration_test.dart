import 'dart:convert';
import 'dart:io';
import 'package:info_cli/codex_registration.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, bundle;
  late File descriptor;
  final suffix = Platform.isWindows ? '.exe' : '';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codex-registry-');
    bundle = Directory('${root.path}/中文 bundle \' \u0024()');
    await bundle.create();
    for (final name in [
      'info-codex',
      'info-codex-hook',
      'info-runtime-worker',
    ]) {
      await File(
        '${bundle.path}/$name$suffix',
      ).writeAsString('PRIVATE-SYNTHETIC-BINARY-$name');
    }
    await Directory(
      '${bundle.path}/template/references',
    ).create(recursive: true);
    await File('${bundle.path}/template/SKILL.md').writeAsString('说明正文');
    await File(
      '${bundle.path}/template/references/read.md',
    ).writeAsString('完整说明');
    descriptor = File('${root.path}/registry/integration.json');
  });
  tearDown(() => root.delete(recursive: true));
  test(
    'explicit registration discovers the complete reviewed Skill and publishes public paths and hashes only',
    () async {
      final result = await registerCodexRuntime(bundle, descriptor: descriptor);
      expect(result['schemaVersion'], 1);
      expect(
        result['cliPath'],
        '${await bundle.resolveSymbolicLinks()}/info-codex$suffix',
      );
      expect(result['skillPath'], endsWith('/template/SKILL.md'));
      expect((result['files'] as List).length, 5);
      expect(jsonEncode(result), isNot(contains('PRIVATE-SYNTHETIC')));
      expect(jsonDecode(await descriptor.readAsString()), result);
      expect(
        await registerCodexRuntime(bundle, descriptor: descriptor),
        result,
      );
      expect(await File('${root.path}/config.toml').exists(), false);
      expect(await Directory('${root.path}/associations').exists(), false);
    },
  );
  test(
    'missing binaries and ambiguous Skill roots keep the existing descriptor untouched',
    () async {
      await registerCodexRuntime(bundle, descriptor: descriptor);
      final before = await descriptor.readAsString();
      await File('${bundle.path}/info-codex$suffix').delete();
      await expectLater(
        registerCodexRuntime(bundle, descriptor: descriptor),
        throwsFormatException,
      );
      expect(await descriptor.readAsString(), before);
      await File('${bundle.path}/info-codex$suffix').writeAsString('restored');
      await Directory(
        '${bundle.path}/skills/agent-info-access',
      ).create(recursive: true);
      await expectLater(
        registerCodexRuntime(bundle, descriptor: descriptor),
        throwsFormatException,
      );
      expect(await descriptor.readAsString(), before);
    },
  );
  test('registration accepts the prepared Skill layout', () async {
    await Directory('${bundle.path}/skills').create();
    await Directory(
      '${bundle.path}/template',
    ).rename('${bundle.path}/skills/agent-info-access');
    final result = await registerCodexRuntime(bundle, descriptor: descriptor);
    expect(result['skillPath'], endsWith('/skills/agent-info-access/SKILL.md'));
    expect(
      (result['files'] as List).map((row) => (row as Map)['path']),
      contains('skills/agent-info-access/references/read.md'),
    );
  });
  test('registration refuses to replace an arbitrary file', () async {
    await descriptor.parent.create();
    await descriptor.writeAsString('PRIVATE-EXISTING-FILE');
    await expectLater(
      registerCodexRuntime(bundle, descriptor: descriptor),
      throwsA(anything),
    );
    expect(await descriptor.readAsString(), 'PRIVATE-EXISTING-FILE');
  });
  test(
    'redirected documentation and registry files cannot read or replace private files',
    () async {
      if (Platform.isWindows) return;
      final outside = File('${root.path}/private.json');
      await outside.writeAsString('PRIVATE-CONTENT');
      await Link(
        '${bundle.path}/template/references/redirect.md',
      ).create(outside.path);
      await expectLater(
        registerCodexRuntime(bundle, descriptor: descriptor),
        throwsFormatException,
      );
      await Link('${bundle.path}/template/references/redirect.md').delete();
      await descriptor.parent.create();
      await Link(descriptor.path).create(outside.path);
      await expectLater(
        registerCodexRuntime(bundle, descriptor: descriptor),
        throwsFormatException,
      );
      expect(await outside.readAsString(), 'PRIVATE-CONTENT');
    },
  );
}
