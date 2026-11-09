import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/macos_agent_bundle.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Map<String, Object?> manifest;
  late MacAgentBundle probe;
  File file(String path) => File('${root.path}/$path');
  Future<void> writeManifest() =>
      file('manifest.json').writeAsString(jsonEncode(manifest));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-bundle-');
    root = Directory(await root.resolveSymbolicLinks());
    final rows = <Map<String, Object?>>[];
    for (final path in MacAgentBundle.requiredFiles) {
      final f = await file(path).create(recursive: true);
      // These are intentionally not runnable programs. Discovery must only read.
      await f.writeAsString('synthetic package entry $path');
      if (path == MacAgentBundle.appExecutable ||
          (path.startsWith('cli/') && !path.startsWith('cli/template/'))) {
        await Process.run('/bin/chmod', ['700', f.path]);
      }
      rows.add({
        'path': path,
        'sha256': sha256.convert(await f.readAsBytes()).toString(),
        'bytes': await f.length(),
        'mode': (await f.stat()).mode & 0xfff,
      });
    }
    manifest = {
      'format': 1,
      'architecture': 'macos-arm64',
      'appIdentity': 'com.example.infoDesktop',
      'sourceDirty': false,
      'sourceCommit': 'a' * 40,
      'files': rows,
    };
    await writeManifest();
    probe = MacAgentBundle(executable: file(MacAgentBundle.appExecutable).path);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'matching package can move as a whole, with no executable launch',
    () async {
      final initial = await probe.read();
      expect(initial.verified, isTrue);
      expect(initial.directory, await root.resolveSymbolicLinks());
      expect(initial.sourceCommit, 'a' * 40);
      expect(
        initial.manifestDigest,
        sha256.convert(await file('manifest.json').readAsBytes()).toString(),
      );
      root = await root.rename('${root.path} 中文 空格');
      final moved = await MacAgentBundle(
        executable: file(MacAgentBundle.appExecutable).path,
      ).read();
      expect(moved.verified, isTrue);
      expect(moved.directory, root.path);
      expect(moved.manifestDigest, initial.manifestDigest);
    },
  );

  test(
    'declared extra Skill references are verified and undeclared or changed references are rejected',
    () async {
      final added = await file(
        'cli/template/references/remote-connection.md',
      ).create();
      await added.writeAsString('synthetic remote connection instructions');
      expect((await probe.read()).verified, false);
      (manifest['files'] as List).add({
        'path': 'cli/template/references/remote-connection.md',
        'bytes': await added.length(),
        'mode': (await added.stat()).mode & 0xfff,
        'sha256': sha256.convert(await added.readAsBytes()).toString(),
      });
      await writeManifest();
      expect((await probe.read()).verified, true);
      await added.writeAsString('modified remote connection instructions');
      expect((await probe.read()).verified, false);
    },
  );

  test('older Mac packages still resolve using their original paths', () async {
    await Directory(
      '${root.path}/app/chiyo.app',
    ).rename('${root.path}/app/info_desktop.app');
    for (final row in manifest['files'] as List<Map<String, Object?>>) {
      row['path'] = (row['path'] as String).replaceFirst(
        'app/chiyo.app/',
        'app/info_desktop.app/',
      );
    }
    await writeManifest();
    final legacy = MacAgentBundle(
      executable: file(MacAgentBundle.legacyAppExecutable).path,
    );
    expect((await legacy.read()).verified, isTrue);
  });

  test(
    'standalone app and absent manifest do not infer installation',
    () async {
      expect(
        (await MacAgentBundle(
          executable: '${root.path}/standalone.app/Contents/MacOS/info_desktop',
        ).read()).status,
        'not_packaged',
      );
      await file('manifest.json').delete();
      final missing = await probe.read();
      expect(missing.status, 'manifest_missing');
      expect(missing.directory, isNull);
    },
  );

  test(
    'every required file is checked, including cached same-size mutation',
    () async {
      for (final path in MacAgentBundle.requiredFiles) {
        expect((await probe.read()).verified, isTrue);
        final f = file(path), original = await file(path).readAsBytes();
        final changed = List<int>.of(original)..[0] ^= 1;
        await f.writeAsBytes(changed);
        expect((await probe.read()).status, 'bundle_invalid', reason: path);
        await f.writeAsBytes(original);
      }
      expect((await probe.read(rehash: true)).verified, isTrue);
    },
  );

  test(
    'missing and non-executable binaries do not fall back to another tool',
    () async {
      await Process.run('/bin/chmod', ['600', file('cli/info').path]);
      expect((await probe.read()).status, 'bundle_invalid');
      await Process.run('/bin/chmod', ['700', file('cli/info').path]);
      await file('cli/info-codex-hook').delete();
      expect((await probe.read()).status, 'bundle_invalid');
    },
  );

  test(
    'duplicate entries, redirected paths and incompatible manifest are rejected',
    () async {
      final original = Map<String, Object?>.from(manifest);
      final rows = manifest['files'] as List;
      for (final patch in <Map<String, Object?>>[
        {'architecture': 'windows-x64'},
        {'sourceDirty': true},
        {'sourceCommit': 'unknown'},
        {'appIdentity': 'preview'},
        {
          'files': [...rows, rows.first],
        },
        {'files': rows.skip(1).toList()},
        {
          'files': [
            {...(rows.first as Map), 'path': '../outside'},
            ...rows.skip(1),
          ],
        },
      ]) {
        manifest = {...original, ...patch};
        await writeManifest();
        expect((await probe.read()).status, 'bundle_invalid');
      }
    },
  );

  test(
    'entry or ancestor symlink cannot borrow another package bytes',
    () async {
      final f = file('cli/info');
      final original = await f.readAsBytes();
      await file('borrowed').writeAsBytes(original);
      await Process.run('/bin/chmod', ['700', file('borrowed').path]);
      await f.delete();
      await Link(f.path).create(file('borrowed').path);
      expect((await probe.read()).status, 'bundle_invalid');
      await Link(f.path).delete();
      await f.writeAsBytes(original);
      await Process.run('/bin/chmod', ['700', f.path]);
      final cli = Directory('${root.path}/cli');
      await cli.rename('${root.path}/borrowed-cli');
      await Link(cli.path).create('${root.path}/borrowed-cli');
      expect((await probe.read()).status, 'bundle_invalid');
    },
  );

  test(
    'malformed or oversized manifest returns bounded failure without raw contents',
    () async {
      for (final text in [
        'private-invalid-json',
        ' ' * (4 * 1024 * 1024 + 1),
      ]) {
        await file('manifest.json').writeAsString(text);
        final result = await probe.read();
        expect(result.status, 'bundle_invalid');
        expect(result.directory, isNull);
        expect(result.manifestDigest, isNull);
      }
    },
  );
  test('unlisted template material cannot be passed on as verified', () async {
    expect((await probe.read()).verified, isTrue);
    await file(
      'cli/template/references/unlisted.md',
    ).writeAsString('unexpected');
    expect((await probe.read()).status, 'bundle_invalid');
  });

  test(
    'app-contained integration works without external delivery files',
    () async {
      final contents = '${root.path}/app/chiyo.app/Contents';
      final embedded = Directory(
        '$contents/${MacAgentBundle.embeddedDirectory}',
      );
      await embedded.create(recursive: true);
      for (final path in MacAgentBundle.embeddedFiles) {
        final target = File('${embedded.path}/$path');
        await target.parent.create(recursive: true);
        await file(path).copy(target.path);
        await Process.run('/bin/chmod', [
          (file(path).statSync().mode & 0xfff).toRadixString(8),
          target.path,
        ]);
      }
      final inner = File('${embedded.path}/manifest.json');
      await inner.writeAsString(
        jsonEncode({
          ...manifest,
          'format': 2,
          'scope': 'app_integration',
          'files': (manifest['files'] as List)
              .where((r) => MacAgentBundle.embeddedFiles.contains(r['path']))
              .toList(),
        }),
      );
      final identity = File('$contents/Resources/agent-source.json');
      await identity.writeAsString(
        jsonEncode({
          'appIdentity': manifest['appIdentity'],
          'sourceCommit': manifest['sourceCommit'],
        }),
      );
      await file('manifest.json').delete();
      await Directory('${root.path}/cli').delete(recursive: true);
      final valid = await probe.read();
      expect(valid.verified, isTrue);
      expect(valid.embedded, isTrue);
      expect(valid.directory, embedded.path);
      await identity.writeAsString(
        jsonEncode({
          'appIdentity': manifest['appIdentity'],
          'sourceCommit': 'b' * 40,
        }),
      );
      expect((await probe.read()).status, 'bundle_invalid');
    },
  );
}
