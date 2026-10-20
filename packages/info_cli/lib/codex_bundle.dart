import 'dart:convert';
import 'dart:io';

/// Renders reviewable installation materials for binaries at their final path.
/// This never merges configuration, installs a Skill, or trusts hooks.
Future<void> writeCodexConfiguration(
  Directory output,
  String skillSource, {
  Directory? finalDirectory,
  String? credentialUseReference,
  String? informationFilesReference,
}) async {
  final bundle = finalDirectory ?? output;
  final suffix = Platform.isWindows ? '.exe' : '';
  final hook = '${bundle.path}/info-codex-hook$suffix';
  String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
  final windowsCommand = "& '${hook.replaceAll("'", "''")}'";
  final encoded = <int>[];
  for (final unit in windowsCommand.codeUnits) {
    encoded.add(unit & 255);
    encoded.add(unit >> 8);
  }
  Map<String, Object> definition(int timeout) => {
    'type': 'command',
    'command': shellQuote(hook),
    'commandWindows':
        'powershell.exe -NoProfile -NonInteractive -EncodedCommand ${base64Encode(encoded)}',
    'timeout': timeout,
    'additionalContextLimit': 0,
  };
  final config = {
    'description':
        'Agent Info development integration. Review before enabling.',
    'hooks': {
      'SessionStart': [
        {
          'matcher': '^(startup|resume|clear|compact|fork)\u0024',
          'hooks': [definition(15)],
        },
      ],
      'SubagentStart': [
        {
          'hooks': [definition(5)],
        },
      ],
      'SessionEnd': [
        {
          'hooks': [definition(3)],
        },
      ],
    },
  };
  await File(
    '${output.path}/hooks.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  final skill = Directory('${output.path}/skills/agent-info-access');
  await skill.create(recursive: true);
  await File('${skill.path}/SKILL.md').writeAsString(
    '$skillSource\nBundle executable: `${bundle.path}/info-codex$suffix`.\n',
  );
  if (credentialUseReference != null) {
    await Directory('${skill.path}/references').create();
    await File(
      '${skill.path}/references/credential-use.md',
    ).writeAsString(credentialUseReference);
  }
  if (informationFilesReference != null) {
    await Directory('${skill.path}/references').create(recursive: true);
    await File(
      '${skill.path}/references/information-files.md',
    ).writeAsString(informationFilesReference);
  }
}
