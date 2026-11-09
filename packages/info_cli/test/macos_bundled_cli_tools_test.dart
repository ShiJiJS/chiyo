import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/macos_agent_bundle.dart';
import 'package:info_cli/macos_bundled_tools.dart';
import 'package:test/test.dart';

void main() {
  test(
    'external and prepared CLI tools use only the matching declared App, including current Skill reference branches',
    () async {
      var root = await Directory.systemTemp.createTemp('matching-cli-tools-');
      root = Directory(await root.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      final rows = <Map<String, Object?>>[];
      for (final path in [
        ...MacAgentBundle.requiredFiles,
        'cli/template/references/remote-connection.md',
        'cli/template/references/information-file-intake.md',
      ]) {
        final file = await File('${root.path}/$path').create(recursive: true);
        await file.writeAsString('synthetic non-program $path');
        if (path == MacAgentBundle.appExecutable ||
            path.startsWith('cli/') && !path.startsWith('cli/template/')) {
          await Process.run('/bin/chmod', ['700', file.path]);
        }
        rows.add({
          'path': path,
          'bytes': await file.length(),
          'mode': (await file.stat()).mode & 0xfff,
          'sha256': sha256.convert(await file.readAsBytes()).toString(),
        });
      }
      await File('${root.path}/manifest.json').writeAsString(
        jsonEncode({
          'format': 1,
          'architecture': 'macos-arm64',
          'appIdentity': 'com.example.infoDesktop',
          'sourceDirty': false,
          'sourceCommit': 'a' * 40,
          'files': rows,
        }),
      );
      final toolRoot =
          '${root.path}/app/chiyo.app/Contents/Resources/ThirdParty';
      final tools = <Map<String, Object?>>[];
      for (final (receiver, path, version) in [
        ('gh_token', 'gh/bin/gh', '2.102.0'),
        ('aws_shared_credentials', 'aws-cli/aws', '2.38.1'),
      ]) {
        final file = await File('$toolRoot/$path').create(recursive: true);
        await file.writeAsString('synthetic non-program $receiver');
        await Process.run('/bin/chmod', ['700', file.path]);
        tools.add({
          'receiver': receiver,
          'executable': path,
          'version': version,
          'executableSha256': sha256
              .convert(await file.readAsBytes())
              .toString(),
        });
      }
      await File('$toolRoot/manifest.json').writeAsString(
        jsonEncode({'format': 1, 'platform': 'macos-arm64', 'tools': tools}),
      );
      final direct = MacBundledTools(executable: '${root.path}/cli/info-codex');
      expect((await direct.read()).take(2).every((t) => t.available), true);
      final reference = await direct.sourceReference();
      expect(reference!['sourceCommit'], 'a' * 40);
      final prepared = await Directory(
        '${root.path}/prepared/cli',
      ).create(recursive: true);
      final binary = await File(
        '${root.path}/cli/info-codex',
      ).copy('${prepared.path}/info-codex');
      final metadata = File('${prepared.path}/${MacBundledTools.sourceFile}');
      await metadata.writeAsString(jsonEncode(reference));
      final probe = MacBundledTools(executable: binary.path);
      expect((await probe.read()).take(2).every((t) => t.available), true);
      final original = await binary.readAsString();
      await binary.writeAsString('different executable source');
      expect((await probe.read()).take(2).every((t) => !t.available), true);
      await binary.writeAsString(original);
      await metadata.writeAsString(
        jsonEncode({...reference, 'sourceCommit': 'b' * 40}),
      );
      expect((await probe.read()).take(2).every((t) => !t.available), true);
      await metadata.writeAsString(jsonEncode(reference));
      final moved = await Directory(
        '${root.path}/app',
      ).rename('${root.path}/moved-app');
      expect((await probe.read()).take(2).every((t) => !t.available), true);
      await moved.rename('${root.path}/app');
      expect((await probe.read()).take(2).every((t) => t.available), true);
      // No executable was run and no user settings or personal App was searched.
    },
    skip: Platform.isWindows,
  );
}
