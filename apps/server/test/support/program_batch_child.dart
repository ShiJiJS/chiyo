import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  // Isolated receiver: no package dependencies, inherited credentials or login.
  final counter = File(args[0]), gate = File(args[1]);
  await counter.writeAsString('start\n', mode: FileMode.append, flush: true);
  final password = Platform.environment['DB_PASSWORD'];
  final token = Platform.environment['SERVICE_TOKEN'];
  final bytes = await stdin.fold<List<int>>([], (a, b) => a..addAll(b));
  final key = args.length < 3 ? <int>[] : await File(args[2]).readAsBytes();
  stdout.writeln(
    jsonEncode({
      'passwordExact': password == '  SYNTHETIC_DB_中文🔐  ',
      'tokenExact': token == 'SYNTHETIC_TOKEN_VALUE',
      'stdinExact': utf8.decode(bytes) == '  SYNTHETIC_DB_中文🔐  ',
      'fileExact': base64Encode(key) == base64Encode([0, 1, 255, 254, 40, 41]),
      'targetTemp':
          Platform.environment['TMPDIR'] ?? Platform.environment['TEMP'],
    }),
  );
  for (final value in [password, token]) {
    if (value == null) continue;
    final secret = utf8.encode(value);
    for (final part in [secret.sublist(0, 3), secret.sublist(3)]) {
      stdout.add(part);
      await stdout.flush();
      stderr.add(part);
      await stderr.flush();
    }
  }
  stdout.add(key);
  await stdout.flush();
  stderr.add(key);
  await stderr.flush();
  while (!await gate.exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
