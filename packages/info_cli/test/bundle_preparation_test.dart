import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'a copied CLI prepares a stable Codex bundle without the Dart SDK or changing existing configuration',
    () async {
      if (!Platform.isWindows) return;
      final delivered = Platform.environment['INFO_TEST_DELIVERY'];
      // The source invocation exercises the same public CLI while iterating. The
      // delivery check invokes its AOT executable from an extracted ZIP instead.
      final root = await Directory.systemTemp.createTemp('info-delivery-');
      addTearDown(() => root.delete(recursive: true));
      final source = Directory('${root.path}/复制 source with spaces');
      await source.create();
      final template = Directory('${source.path}/template');
      await template.create();
      final repo = Directory.current.parent.parent;
      await File(
        '${repo.path}/integrations/codex/skills/agent-info-access/SKILL.md',
      ).copy('${template.path}/SKILL.md');
      for (final name in [
        'info-codex',
        'info-codex-hook',
        'info-runtime-worker',
      ]) {
        if (delivered == null) {
          final entry = name == 'info-runtime-worker'
              ? 'runtime_worker'
              : name.endsWith('hook')
              ? 'codex_hook'
              : 'codex_info';
          final build = await Process.run(Platform.resolvedExecutable, [
            'compile',
            'exe',
            'bin/$entry.dart',
            '-o',
            '${source.path}/$name.exe',
          ]);
          expect(build.exitCode, 0, reason: '${build.stderr}');
        } else {
          await File(
            '$delivered/cli/$name.exe',
          ).copy('${source.path}/$name.exe');
        }
      }
      final output = '${root.path}/最终 bundle with spaces';
      Future<ProcessResult> prepare() => Process.run(
        delivered == null
            ? Platform.resolvedExecutable
            : '$delivered/cli/info-prepare-codex.exe',
        [
          if (delivered == null) ...['run', 'bin/prepare_codex.dart'],
          '--source-bundle',
          source.path,
          output,
        ],
        environment: {
          'PATH': '${Platform.environment['SystemRoot']}\\System32',
        },
      );
      final prepared = await prepare();
      expect(prepared.exitCode, 0, reason: '${prepared.stderr}');
      expect(
        await File('$output/info-runtime-worker.exe').exists(),
        isTrue,
        reason:
            'A prepared executable must retain the worker required for approved launches.',
      );
      final configFile = File('$output/hooks.json');
      final configBefore = await configFile.readAsString();
      final config = jsonDecode(configBefore) as Map<String, dynamic>;
      final hook = config['hooks']['SessionStart'][0]['hooks'][0];
      final command = (hook['commandWindows'] as String).split(' ');
      final process = await Process.start(
        command.first,
        command.sublist(1),
        environment: {
          'PATH': '${Platform.environment['SystemRoot']}\\System32',
        },
      );
      final result = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(
        jsonEncode({'hook_event_name': 'SessionStart', 'source': 'compact'}),
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
      expect(
        jsonDecode(await result)['hookSpecificOutput']['additionalContext'],
        contains('Retain'),
      );
      final skill = await File(
        '$output/skills/agent-info-access/SKILL.md',
      ).readAsString();
      expect(skill, contains('$output/info-codex.exe'));
      final refused = await prepare();
      expect(refused.exitCode, 64);
      expect(await configFile.readAsString(), configBefore);
      // The copied executable still accepts JSON after the source directory is
      // removed. No generated command depends on its build/package location.
      await source.delete(recursive: true);
      final cli = await Process.start(
        '$output/info-codex.exe',
        [],
        environment: {
          'PATH': '${Platform.environment['SystemRoot']}\\System32',
        },
      );
      final response = cli.stdout.transform(utf8.decoder).join();
      cli.stdin.writeln('{}');
      await cli.stdin.close();
      expect(await cli.exitCode, 0);
      expect(jsonDecode(await response)['status'], 'association_unavailable');
    },
  );
}
