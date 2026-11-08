import 'dart:convert';
import 'dart:io';
import 'package:info_remote/agent_connection.dart';

import 'package:test/test.dart';

void main() {
  test(
    'a copied CLI prepares a stable Codex bundle without the Dart SDK or changing existing configuration',
    () async {
      final suffix = Platform.isWindows ? '.exe' : '';
      final restrictedPath = Platform.isWindows
          ? '${Platform.environment['SystemRoot']}\\System32'
          : '/usr/bin:/bin';
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
      final sourceTemplate = delivered == null
          ? '${repo.path}/integrations/codex/skills/agent-info-access'
          : '$delivered/cli/template';
      await File('$sourceTemplate/SKILL.md').copy('${template.path}/SKILL.md');
      await Directory('${template.path}/references').create();
      final credentialReference = File(
        '$sourceTemplate/references/credential-use.md',
      );
      await credentialReference.copy(
        '${template.path}/references/credential-use.md',
      );
      final fileReference = File(
        '$sourceTemplate/references/information-files.md',
      );
      await fileReference.copy(
        '${template.path}/references/information-files.md',
      );
      final extraReferences = <String>[];
      await for (final file in Directory('$sourceTemplate/references').list()) {
        if (file is! File || !file.path.endsWith('.md')) continue;
        final name = file.uri.pathSegments.last;
        if (const {'credential-use.md', 'information-files.md'}.contains(name)) {
          continue;
        }
        await file.copy('${template.path}/references/$name');
        extraReferences.add(name);
      }
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
            '${source.path}/$name$suffix',
          ]);
          expect(build.exitCode, 0, reason: '${build.stderr}');
        } else {
          await File(
            '$delivered/cli/$name$suffix',
          ).copy('${source.path}/$name$suffix');
        }
      }
      final output = Platform.isMacOS
          ? "${root.path}/最终 bundle ' \$(touch injected)"
          : '${root.path}/最终 bundle with spaces';
      Future<ProcessResult> prepare() => Process.run(
        delivered == null
            ? Platform.resolvedExecutable
            : '$delivered/cli/info-prepare-codex$suffix',
        [
          if (delivered == null) ...['run', 'bin/prepare_codex.dart'],
          '--source-bundle',
          source.path,
          output,
        ],
        environment: {'PATH': restrictedPath},
      );
      final prepared = await prepare();
      expect(prepared.exitCode, 0, reason: '${prepared.stderr}');
      expect(
        await File('$output/info-runtime-worker$suffix').exists(),
        isTrue,
        reason:
            'A prepared executable must retain the worker required for approved launches.',
      );
      final configFile = File('$output/hooks.json');
      final configBefore = await configFile.readAsString();
      final config = jsonDecode(configBefore) as Map<String, dynamic>;
      final hook = config['hooks']['SessionStart'][0]['hooks'][0];
      final command = Platform.isWindows
          ? (hook['commandWindows'] as String).split(' ')
          : ['/bin/sh', '-c', hook['command'] as String];
      final process = await Process.start(
        command.first,
        command.sublist(1),
        workingDirectory: root.path,
        environment: {'PATH': restrictedPath},
      );
      final result = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(
        jsonEncode({'hook_event_name': 'SessionStart', 'source': 'compact'}),
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
      if (Platform.isMacOS) {
        expect(await File('${root.path}/injected').exists(), isFalse);
      }
      expect(
        jsonDecode(await result)['hookSpecificOutput']['additionalContext'],
        contains('Retain'),
      );
      final skill = await File(
        '$output/skills/agent-info-access/SKILL.md',
      ).readAsString();
      expect(skill, contains('$output/info-codex$suffix'));
      expect(
        await File(
          '$output/skills/agent-info-access/references/credential-use.md',
        ).readAsString(),
        await credentialReference.readAsString(),
      );
      final refused = await prepare();
      if (Platform.isMacOS) {
        final profile = AgentConnectionProfile(
          address: Uri.parse('https://localhost:47126'),
          deviceToken: '${'a' * 22}.${'b' * 43}',
          serverId: 'synthetic-bundle-server',
        );
        final profileFile = await profile.saveIn(
          Directory("${root.path}/private ' \$(touch profile-injected)"),
        );
        final stateRoot = "${root.path}/state ' \$(touch state-injected)";
        final remoteOutput = '${root.path}/remote prepared';
        final remotePrepared = await Process.run(
          delivered == null
              ? Platform.resolvedExecutable
              : '$delivered/cli/info-prepare-codex$suffix',
          [
            if (delivered == null) ...['run', 'bin/prepare_codex.dart'],
            '--source-bundle',
            source.path,
            '--connection',
            profileFile.path,
            '--state-root',
            stateRoot,
            remoteOutput,
          ],
          environment: {'PATH': restrictedPath},
        );
        expect(remotePrepared.exitCode, 0, reason: '${remotePrepared.stderr}');
        final remoteConfig = jsonDecode(
          await File('$remoteOutput/hooks.json').readAsString(),
        );
        final remoteCommand =
            remoteConfig['hooks']['SessionStart'][0]['hooks'][0]['command']
                as String;
        final remoteProcess = await Process.start(
          '/bin/sh',
          ['-c', remoteCommand],
          workingDirectory: root.path,
          environment: {'PATH': restrictedPath},
        );
        final remoteResult = remoteProcess.stdout
            .transform(utf8.decoder)
            .join();
        final remoteErrors = remoteProcess.stderr
            .transform(utf8.decoder)
            .join();
        remoteProcess.stdin.writeln(
          jsonEncode({'hook_event_name': 'SessionStart', 'source': 'compact'}),
        );
        await remoteProcess.stdin.close();
        expect(await remoteProcess.exitCode, 0);
        expect(await remoteErrors, isEmpty);
        expect(
          jsonDecode(
            await remoteResult,
          )['hookSpecificOutput']['additionalContext'],
          contains('Retain'),
        );
        expect(await File('${root.path}/profile-injected').exists(), isFalse);
        expect(await File('${root.path}/state-injected').exists(), isFalse);
        final remoteSkill = await File(
          '$remoteOutput/skills/agent-info-access/SKILL.md',
        ).readAsString();
        expect(remoteSkill, contains(profileFile.path));
        expect(remoteSkill, contains(stateRoot));
        expect(remoteSkill.contains(profile.deviceToken), isFalse);
      }
      for (final name in extraReferences) {
        expect(
          await File(
            '$output/skills/agent-info-access/references/$name',
          ).readAsString(),
          await File('$sourceTemplate/references/$name').readAsString(),
        );
      }
      expect(
        await File(
          '$output/skills/agent-info-access/references/information-files.md',
        ).readAsString(),
        await fileReference.readAsString(),
      );
      expect(refused.exitCode, 64);
      expect(await configFile.readAsString(), configBefore);
      // The copied executable still accepts JSON after the source directory is
      // removed. No generated command depends on its build/package location.
      await source.delete(recursive: true);
      final cli = await Process.start(
        '$output/info-codex$suffix',
        [],
        environment: {'PATH': restrictedPath},
      );
      final response = cli.stdout.transform(utf8.decoder).join();
      cli.stdin.writeln('{}');
      await cli.stdin.close();
      expect(await cli.exitCode, 0);
      expect(jsonDecode(await response)['status'], 'association_unavailable');
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
  );
}
