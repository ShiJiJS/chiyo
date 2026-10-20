import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  stdout.writeln(
    jsonEncode({
      'tokenMatches': Platform.environment['GH_TOKEN'] == 'synthetic-token',
      'literalArguments': args.join('|') == 'api|user|--method|GET',
    }),
  );
  await stdout.flush();
  await Future<void>.delayed(const Duration(milliseconds: 200));
}
