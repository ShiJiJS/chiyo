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
  String? connectionFile,
  String? stateRoot,
  Map<String, String> additionalReferences = const {},
}) async {
  final bundle = finalDirectory ?? output;
  final suffix = Platform.isWindows ? '.exe' : '';
  final hook = '${bundle.path}/info-codex-hook$suffix';
  String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
  final hookArguments = [
    if (connectionFile != null) ...['--connection', connectionFile],
    if (stateRoot != null) ...['--state-root', stateRoot],
  ];
  String psQuote(String value) => "'${value.replaceAll("'", "''")}'";
  final windowsCommand = '& ${[hook, ...hookArguments].map(psQuote).join(' ')}';
  final encoded = <int>[];
  for (final unit in windowsCommand.codeUnits) {
    encoded.add(unit & 255);
    encoded.add(unit >> 8);
  }
  Map<String, Object> definition(int timeout) => {
    'type': 'command',
    'command': [hook, ...hookArguments].map(shellQuote).join(' '),
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
    '$skillSource\nBundle executable: `${bundle.path}/info-codex$suffix`.\n'
    '${connectionFile == null ? '' : 'Connection profile: `$connectionFile`.\n'}'
    '${stateRoot == null ? '' : 'Session state directory: `$stateRoot`.\n'}',
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
  for (final reference in additionalReferences.entries) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*\.md$').hasMatch(reference.key)) {
      throw const FormatException('Invalid reference name');
    }
    await Directory('${skill.path}/references').create(recursive: true);
    await File(
      '${skill.path}/references/${reference.key}',
    ).writeAsString(reference.value);
  }
}
