import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  stdout.writeln(
    jsonEncode({
      'tokenMatches': Platform.environment['GH_TOKEN'] == 'synthetic-token',
      'argsMatch': args.join('|') == 'api|user|--method|GET',
      'privateConfig':
          Platform.environment['GH_CONFIG_DIR'] ==
              Platform.environment['HOME'] &&
          Platform.environment['GH_HOST'] == 'github.com' &&
          Platform.environment['GH_PROMPT_DISABLED'] == '1',
      'sessionAbsent': Platform.environment.keys.every(
        (k) =>
            !k.contains('INFO_') &&
            !k.contains('CODEX') &&
            !k.contains('GITHUB_TOKEN'),
      ),
    }),
  );
}
