@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/windows_agent_bundle.dart';
import 'package:info_cli/windows_bundled_tools.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final tools = [
    ('gh_token', 'gh/bin/gh.exe', '2.102.0'),
    ('aws_shared_credentials', 'aws-cli/aws.exe', '2.38.1'),
  ];
  File file(String path) => File('${root.path}/$path');
  Future<void> put(String path, String text) async =>
      (await file(path).create(recursive: true)).writeAsString(text);
  Future<Map<String, Object?>> row(String path, {String prefix = ''}) async => {
    'path': path.substring(prefix.length),
    'bytes': await file(path).length(),
    'sha256': (await sha256.bind(file(path).openRead()).first).toString(),
  };
  Future<void> seal() async {
    final paths = <String>[
      for (final e in await Directory(
        '${root.path}/tools',
      ).list(recursive: true).toList())
        if (e is File && !e.path.endsWith('manifest.json'))
          e.path.substring(root.path.length + 1).replaceAll('\\', '/'),
    ];
    final inventory = [
      for (final path in paths) await row(path, prefix: 'tools/'),
    ];
    await put(
      'tools/manifest.json',
      jsonEncode({
        'format': 1,
        'platform': 'windows-x64',
        'files': inventory,
        'tools': [
          for (final (receiver, path, version) in tools)
            {
              'receiver': receiver,
              'executable': path,
              'version': version,
              'executableSha256': (await row('tools/$path'))['sha256'],
            },
        ],
      }),
    );
    await put(
      'manifest.json',
      jsonEncode({
        'format': 2,
        'product': 'Agent Info Manage',
        'architecture': 'windows-x64',
        'sourceDirty': false,
        'sourceCommit': 'a' * 40,
        'files': [
          for (final path in [
            ...WindowsAgentBundle.requiredFiles,
            ...paths,
            'tools/manifest.json',
          ])
            await row(path),
        ],
      }),
    );
  }

  Future<bool> available(WindowsBundledTools probe) async =>
      (await probe.read()).take(2).every((t) => t.available);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chiyo-windows-tools-');
    root = Directory(await root.resolveSymbolicLinks());
    for (final path in WindowsAgentBundle.requiredFiles) {
      await put(
        path,
        path.endsWith('/info-runtime-worker.exe')
            ? 'same worker'
            : 'non-executable fixture $path',
      );
    }
    for (final (_, path, _) in tools) {
      await put('tools/$path', 'non-executable tool $path');
    }
    await put('tools/aws-cli/dependency.dll', 'dependency bytes');
    await seal();
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'App and matching prepared CLI observe only verified shipped tools',
    () async {
      expect(
        await available(
          WindowsBundledTools(
            executable: file(WindowsAgentBundle.appExecutable).path,
          ),
        ),
        true,
      );
      final direct = WindowsBundledTools(
        executable: file('cli/info-codex.exe').path,
      );
      expect(await available(direct), true);
      final reference = (await direct.sourceReference())!;
      expect(reference['sourceCommit'], 'a' * 40);
      final preparedDirectory = await Directory(
        '${root.path}/prepared',
      ).create();
      final binary = await file(
        'cli/info-codex.exe',
      ).copy('${preparedDirectory.path}/info-codex.exe');
      await put(
        'prepared/${WindowsBundledTools.sourceFile}',
        jsonEncode(reference),
      );
      final prepared = WindowsBundledTools(executable: binary.path);
      expect(await available(prepared), true);
      await binary.writeAsString('different CLI');
      expect(await available(prepared), false);
      await file('cli/info-codex.exe').copy(binary.path);
      await put(
        'prepared/${WindowsBundledTools.sourceFile}',
        jsonEncode({...reference, 'sourceCommit': 'b' * 40}),
      );
      expect(await available(prepared), false);
    },
  );
  test(
    'dependency tampering and undeclared DLL reject tools, restore succeeds',
    () async {
      final probe = WindowsBundledTools(executable: file('cli/info.exe').path);
      expect(await available(probe), true);
      await put('tools/aws-cli/dependency.dll', 'changed dependency');
      expect(await available(probe), false);
      await put('tools/aws-cli/dependency.dll', 'dependency bytes');
      expect(await available(probe), true);
      await put('tools/aws-cli/extra.dll', 'not declared');
      expect(await available(probe), false);
    },
  );
  test('complete package can move, stale external pointer cannot', () async {
    final reference = (await WindowsBundledTools(
      executable: file('cli/info-codex.exe').path,
    ).sourceReference())!;
    root = await root.rename('${root.path} 中文 空格');
    final probe = WindowsBundledTools(executable: file('cli/info.exe').path);
    expect(await available(probe), true);
    await Directory('${root.path}/prepared').create();
    await file('cli/info-codex.exe').copy(file('prepared/info-codex.exe').path);
    await put(
      'prepared/${WindowsBundledTools.sourceFile}',
      jsonEncode(reference),
    );
    expect(
      await available(
        WindowsBundledTools(executable: file('prepared/info-codex.exe').path),
      ),
      false,
    );
  });
  test(
    'unpackaged CLI reports missing bundles and independent system SSH',
    () async {
      final rows = await WindowsBundledTools(
        executable: file('loose/info.exe').path,
      ).read();
      expect(
        rows
            .take(2)
            .every(
              (t) => !t.available && t.unavailableReason == 'bundle_missing',
            ),
        true,
      );
      expect(rows.last.receiver, 'ssh_identity');
      expect(rows.last.source, 'system');
    },
  );
  test(
    'official workspace programs pass unchanged production version/identity checks',
    () async {
      final path = Platform.environment['CHIYO_WINDOWS_TOOLS_CHECK']!;
      for (final (receiver, relative, _) in tools) {
        final identity = await inspectCredentialExecutable(
          '$path/$relative',
          receiver,
        );
        expect(identity.byteLength, greaterThan(0));
        expect(identity.sha256, startsWith('sha256:'));
      }
      final system = Platform.environment['SystemRoot']!;
      expect(
        (await inspectCredentialExecutable(
          '$system/System32/OpenSSH/ssh.exe',
          'ssh_identity',
        )).byteLength,
        greaterThan(0),
      );
    },
    skip: Platform.environment['CHIYO_WINDOWS_TOOLS_CHECK'] == null,
  );
}
