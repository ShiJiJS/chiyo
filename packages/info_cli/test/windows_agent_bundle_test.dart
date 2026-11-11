import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/windows_agent_bundle.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Map<String, Object?> manifest;
  late WindowsAgentBundle probe;
  File file(String relative) => File('${root.path}/$relative');
  Future<void> writeManifest() =>
      file('manifest.json').writeAsString(jsonEncode(manifest));
  Future<void> declare(String relative, String content) async {
    final entry = await file(relative).create(recursive: true);
    await entry.writeAsString(content);
    (manifest['files'] as List).add({
      'path': relative,
      'bytes': await entry.length(),
      'sha256': sha256.convert(await entry.readAsBytes()).toString(),
    });
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chiyo-windows-bundle-');
    root = Directory(await root.resolveSymbolicLinks());
    manifest = {
      'format': 2,
      'product': 'Agent Info Manage',
      'architecture': 'windows-x64',
      'sourceDirty': false,
      'sourceCommit': 'a' * 40,
      'files': <Map<String, Object?>>[],
    };
    for (final path in WindowsAgentBundle.requiredFiles) {
      // Intentionally not executable: package observation must only read.
      await declare(
        path,
        path.endsWith('/info-runtime-worker.exe')
            ? 'same compiled worker'
            : 'synthetic package $path',
      );
    }
    await declare('app/data/app.so', 'synthetic application asset');
    await writeManifest();
    probe = WindowsAgentBundle(
      executable: file(WindowsAgentBundle.appExecutable).path,
    );
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'running App recognizes complete package after moving its whole directory',
    () async {
      final original = await probe.read();
      expect(original.verified, isTrue);
      expect(original.sourceCommit, 'a' * 40);
      expect(
        original.manifestDigest,
        sha256.convert(await file('manifest.json').readAsBytes()).toString(),
      );
      root = await root.rename('${root.path} 中文 空格');
      final moved = await WindowsAgentBundle(
        executable: file(WindowsAgentBundle.appExecutable).path,
      ).read();
      expect(moved.verified, isTrue);
      expect(moved.directory, root.path);
      expect(moved.manifestDigest, original.manifestDigest);
    },
    skip: !Platform.isWindows,
  );

  test(
    'loose build and absent manifest do not claim host integration',
    () async {
      expect(
        (await WindowsAgentBundle(
          executable: '${root.path}/Release/info_desktop.exe',
        ).read()).status,
        'not_packaged',
      );
      await file('manifest.json').delete();
      expect((await probe.read()).status, 'manifest_missing');
    },
  );

  test(
    'every declared payload is hashed and missing or changed files fail closed',
    () async {
      expect((await probe.read()).verified, isTrue);
      await file('app/data/app.so').writeAsString('changed application asset');
      expect((await probe.read()).status, 'bundle_invalid');
      await file(
        'app/data/app.so',
      ).writeAsString('synthetic application asset');
      expect((await probe.read(rehash: true)).verified, isTrue);
      await file('cli/info-codex-hook.exe').delete();
      expect((await probe.read()).status, 'bundle_invalid');
    },
  );

  test(
    'all references must ship, declared additions hash, undeclared additions fail',
    () async {
      await declare(
        'cli/template/references/additional.md',
        'additional instructions',
      );
      expect((await probe.read()).status, 'bundle_invalid');
      await writeManifest();
      expect((await probe.read()).verified, isTrue);
      await file('cli/template/references/remote-connection.md').delete();
      expect((await probe.read()).status, 'bundle_invalid');
    },
  );

  test(
    'manifest identity, duplicate Windows paths and traversal cannot be accepted',
    () async {
      final original = jsonEncode(manifest);
      for (final replacement in [
        {'architecture': 'macos-arm64'},
        {'sourceDirty': true},
        {'sourceCommit': 'not-a-commit'},
        {'product': 'another application'},
      ]) {
        manifest = Map<String, Object?>.from(jsonDecode(original) as Map)
          ..addAll(replacement);
        await writeManifest();
        expect((await probe.read()).status, 'bundle_invalid');
      }
      for (final path in [
        'CLI/info.exe',
        '../outside.exe',
        '/absolute.exe',
        r'app\redirect.exe',
        'app/x:stream',
        'app/x.',
      ]) {
        manifest = Map<String, Object?>.from(jsonDecode(original) as Map);
        (manifest['files'] as List).add({
          'path': path,
          'bytes': 1,
          'sha256': 'b' * 64,
        });
        await writeManifest();
        expect((await probe.read()).status, 'bundle_invalid', reason: path);
      }
    },
  );

  test(
    'different workers fail even when both declared hashes match their own files',
    () async {
      final worker = file('app/info-runtime-worker.exe');
      await worker.writeAsString('different worker');
      final row = (manifest['files'] as List).cast<Map>().singleWhere(
        (row) => row['path'] == 'app/info-runtime-worker.exe',
      );
      row['bytes'] = await worker.length();
      row['sha256'] = sha256.convert(await worker.readAsBytes()).toString();
      await writeManifest();
      expect((await probe.read()).status, 'bundle_invalid');
    },
  );

  test('bounded verification checks late files and can recover after rejection', () async {
    final original = 'SYNTHETIC_PAYLOAD_' * 512;
    for (var index = 0; index < 32; index++) {
      await declare('tools/synthetic/payload-$index.dat', original);
    }
    await writeManifest();
    expect((await probe.read(rehash: true)).verified, isTrue);
    final late = file('tools/synthetic/payload-31.dat');
    await late.writeAsString('X' * original.length);
    expect((await probe.read(rehash: true)).status, 'bundle_invalid');
    await late.writeAsString(original);
    expect((await probe.read(rehash: true)).verified, isTrue);
  });
}
