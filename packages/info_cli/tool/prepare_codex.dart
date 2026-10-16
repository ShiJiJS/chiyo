import 'dart:convert';
import 'dart:io';

/// Creates a reviewable bundle only. Does not install or trust any hooks.
Future<void> main(List<String> args) async {
  if (args.length != 1 || (!Platform.isWindows && !Platform.isMacOS)) {
    stderr.writeln(
      'Usage: dart run tool/prepare_codex.dart <new-bundle-directory>',
    );
    exitCode = 64;
    return;
  }
  final output = Directory(args.single).absolute;
  if (await output.exists()) {
    stderr.writeln('Destination exists; choose a new bundle directory.');
    exitCode = 64;
    return;
  }
  final package = File.fromUri(Platform.script).parent.parent;
  final repository = package.parent.parent;
  await output.create(recursive: true);
  final suffix = Platform.isWindows ? '.exe' : '';
  final hook = '${output.path}/info-codex-hook$suffix';
  for (final entry in {
    'codex_hook': 'info-codex-hook',
    'codex_info': 'info-codex',
  }.entries) {
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '${package.path}/bin/${entry.key}.dart',
      '-o',
      '${output.path}/${entry.value}$suffix',
    ], workingDirectory: package.path);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      exitCode = result.exitCode;
      return;
    }
  }
  String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
  final windowsCommand = "& '${hook.replaceAll("'", "''")}'";
  final encoded = <int>[];
  for (final unit in windowsCommand.codeUnits) {
    encoded.add(unit & 255);
    encoded.add(unit >> 8);
  }
  final config = {
    'description':
        'Agent Info development integration. Review before enabling.',
    'hooks': {
      'SessionStart': [
        {
          'matcher': '^(startup|resume|clear|compact|fork)\u0024',
          'hooks': [
            {
              'type': 'command',
              'command': shellQuote(hook),
              'commandWindows':
                  'powershell.exe -NoProfile -NonInteractive -EncodedCommand ${base64Encode(encoded)}',
              'timeout': 15,
              'additionalContextLimit': 0,
            },
          ],
        },
      ],
    },
  };
  await File(
    '${output.path}/hooks.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  final skill = Directory('${output.path}/skills/agent-info-access');
  await skill.create(recursive: true);
  final source = await File(
    '${repository.path}/integrations/codex/skills/agent-info-access/SKILL.md',
  ).readAsString();
  await File('${skill.path}/SKILL.md').writeAsString(
    '$source\nBundle executable: `${output.path}/info-codex$suffix`.\n',
  );
  stdout.writeln('Prepared bundle: ${output.path}');
  stdout.writeln(
    'No hooks installed or trusted. Follow integrations/codex/README.md.',
  );
}
