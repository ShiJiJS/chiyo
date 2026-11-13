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
  if ((mode['mode'] as String).startsWith('guard-')) {
    final config =
        jsonDecode(
              RegExp(r'const config = (.+);').firstMatch(source)!.group(1)!,
            )
            as Map;
    final guard = config['guard'] as Map;
    final http = HttpClient();
    final decisions = <bool>[];
    try {
      for (var i = 0; i < (mode['mode'] == 'guard-duplicate' ? 2 : 1); i++) {
        final request = await http.openUrl(
          mode['mode'] == 'guard-method' ? 'GET' : 'POST',
          Uri.parse(guard['url'] as String),
        );
        request.headers.set(
          'authorization',
          'Bearer ${mode['mode'] == 'guard-capability' ? 'invalid' : guard['capability']}',
        );
        if (mode['mode'] == 'guard-origin') {
          request.headers.set('origin', 'https://synthetic.invalid');
        }
        if (mode['mode'] != 'guard-method') {
          request.write(mode['mode'] == 'guard-body' ? '[]' : '{}');
        }
        final response = await request.close();
        final decision =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        decisions.add(decision['allowed'] == true);
        if (decision['allowed'] != true) {
          receipt({'status': 'refused', 'code': decision['code']});
          return;
        }
      }
      receipt({'status': 'filled'});
    } finally {
      http.close(force: true);
    }
    return;
  }
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
