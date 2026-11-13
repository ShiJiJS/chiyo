import 'dart:convert';
import 'dart:io';

// A synthetic installed helper. It deliberately echoes source in failure modes
// to verify the production module never propagates browser diagnostics.
Future<void> main(List<String> args) async {
  final root = File(Platform.resolvedExecutable).parent;
  final mode =
      jsonDecode(await File('${root.path}/mode.json').readAsString()) as Map;
  final source = await utf8.decoder.bind(stdin).join();
  final prefix =
      jsonDecode(
            RegExp(r'const prefix = ("[^"]+");').firstMatch(source)!.group(1)!,
          )
          as String;
  final password = mode['password'] as String;
  await File('${root.path}/observed.json').writeAsString(
    jsonEncode({
      'args': args,
      'argvContainsMaterial': args.any((arg) => arg.contains(password)),
      'environmentContainsMaterial': Platform.environment.values.any(
        (value) => value.contains(password),
      ),
      'stdinContainsMaterial': source.contains(password),
    }),
  );
  void receipt(Map<String, Object?> value) =>
      stderr.writeln(prefix + jsonEncode(value));
  switch (mode['mode']) {
    case 'ready':
      receipt({
        'status': 'ready',
        'instanceId': 'a' * 64,
        'structure': {'form': {}, 'fields': [], 'selected': {}},
      });
    case 'filled':
      receipt({'status': 'filled', 'untrusted': password});
    case 'echo':
      stdout.writeln(source);
      stderr.writeln('browser failed: $password');
      exitCode = 1;
    case 'invalid-code':
      receipt({'status': 'refused', 'code': password});
    case 'duplicate':
      receipt({'status': 'filled'});
      receipt({'status': 'filled'});
    case 'malformed':
      stderr.writeln('${prefix}not-json:$password');
    case 'excessive':
      stdout.write('x' * (1024 * 1024 + 1));
    case 'timeout':
      await Future<void>.delayed(const Duration(seconds: 20));
    default:
      throw StateError('Unknown fixture mode');
  }
}
