import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/macos_bundled_tools.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String executable;
  late Directory tools;
  late Map<String, dynamic> manifest;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mac-tool-discovery-');
    executable = '${root.path}/应用 有空格.app/Contents/MacOS/info_desktop';
    await File(executable).create(recursive: true);
    tools = await Directory(
      '${File(executable).parent.parent.path}/Resources/ThirdParty',
    ).create(recursive: true);
    final entries = <Map<String, Object?>>[];
    for (final entry in [
      ('gh_token', 'gh/bin/gh', '2.102.0'),
      ('aws_shared_credentials', 'aws-cli/aws', '2.38.1'),
    ]) {
      final file = await File(
        '${tools.path}/${entry.$2}',
      ).create(recursive: true);
      await file.writeAsString('synthetic non-program ${entry.$1}');
      await Process.run('/bin/chmod', ['700', file.path]);
      entries.add({
        'receiver': entry.$1,
        'executable': entry.$2,
        'version': entry.$3,
        'executableSha256': sha256.convert(await file.readAsBytes()).toString(),
      });
    }
    manifest = {'format': 1, 'platform': 'macos-arm64', 'tools': entries};
    await File(
      '${tools.path}/manifest.json',
    ).writeAsString(jsonEncode(manifest));
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'moved app uses its current paths; public discovery grants nothing',
    () async {
      final moved = await Directory(
        '${root.path}/应用 有空格.app',
      ).rename('${root.path}/移动 中文.app');
      final path = '${moved.path}/Contents/MacOS/info_desktop';
      final server = await AgentServer.start(
        InformationService(repository: MemoryInformationRepository()).agent,
        port: 0,
        credentialTools: MacBundledTools(executable: path).read,
      );
      addTearDown(server.close);
      final client = AgentClient(server.port);
      addTearDown(client.close);
      final result = await client.execute({'command': 'capabilities'});
      expect(result['capabilities'], contains('credential-tools.v1'));
      final rows = result['credentialTools'] as List;
      expect(rows.take(2).every((row) => row['available'] == true), isTrue);
      expect(rows.first['executable'], startsWith(moved.path));
      expect(rows.first.keys.toSet(), {
        'receiver',
        'source',
        'available',
        'version',
        'executable',
      });
      expect(jsonEncode(result), isNot(contains('sessionSecret')));
      expect(client.sessionSecret, isNull);
      expect(client.endCapability, isNull);
    },
    skip: Platform.isWindows,
  );

  test('tampered or non-executable entry does not fall back to PATH', () async {
    await File('${tools.path}/gh/bin/gh').writeAsString('changed');
    await Process.run('/bin/chmod', ['600', '${tools.path}/aws-cli/aws']);
    final rows = await MacBundledTools(executable: executable).read();
    for (final row in rows.take(2)) {
      expect(row.available, isFalse);
      expect(row.executable, isNull);
      expect(row.unavailableReason, 'bundle_invalid');
    }
  }, skip: Platform.isWindows);

  test(
    'missing manifest, traversal, duplicate entry and symlink escape fail closed',
    () async {
      final file = File('${tools.path}/manifest.json');
      await file.delete();
      expect(
        (await MacBundledTools(executable: executable).read()).first.available,
        isFalse,
      );
      final entries = manifest['tools'] as List;
      final gh = Map<String, dynamic>.from(entries.first as Map);
      for (final invalid in [
        [
          {...gh, 'executable': '../../outside'},
          entries.last,
        ],
        [gh, gh, entries.last],
        [
          {...gh, 'version': 'next-unverified-version'},
          entries.last,
        ],
      ]) {
        await file.writeAsString(jsonEncode({...manifest, 'tools': invalid}));
        expect(
          (await MacBundledTools(
            executable: executable,
          ).read()).first.available,
          isFalse,
        );
      }
      await file.writeAsString(jsonEncode(manifest));
      final entry = File('${tools.path}/gh/bin/gh');
      final outside = await entry.copy('${root.path}/outside');
      await entry.delete();
      await Link(entry.path).create(outside.path);
      expect(
        (await MacBundledTools(executable: executable).read()).first.available,
        isFalse,
      );
      await Link(entry.path).delete();
      await outside.copy(entry.path);
      final original = tools.path;
      await tools.rename('${root.path}/redirected');
      await Link(original).create('${root.path}/redirected');
      expect(
        (await MacBundledTools(executable: executable).read()).first.available,
        isFalse,
      );
    },
    skip: Platform.isWindows,
  );
}
