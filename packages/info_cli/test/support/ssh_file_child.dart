import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> input) async {
  final expected = input.first, args = input.skip(1).toList();
  final identity = File(args[args.indexOf('-i') + 1]),
      config = File(args[args.indexOf('-F') + 1]);
  String option(String name) {
    final value = args.firstWhere((v) => v.startsWith('$name='));
    return value.substring(name.length + 1).replaceAll('"', '');
  }

  final hosts = File(option('UserKnownHostsFile')),
      global = File(option('GlobalKnownHostsFile'));
  stdout.writeln(
    jsonEncode({
      'keyExact':
          await identity.readAsString() == 'SYNTHETIC_SSH_PRIVATE_MATERIAL',
      'hostsExact': base64Encode(await hosts.readAsBytes()) == expected,
      'emptyConfig': await config.length() == 0,
      'emptyGlobal': await global.length() == 0,
      'strictHost': args.contains('StrictHostKeyChecking=yes'),
      'oneIdentity':
          args.contains('IdentitiesOnly=yes') &&
          args.contains('IdentityAgent=none'),
      'batch': args.contains('BatchMode=yes') && args.contains('-T'),
      'noAmbientAuth':
          !Platform.environment.containsKey('SSH_AUTH_SOCK') &&
          !Platform.environment.containsKey('SSH_ASKPASS') &&
          !Platform.environment.containsKey('INFO_SESSION_SECRET'),
    }),
  );
  await stdout.flush();
  await Future<void>.delayed(const Duration(milliseconds: 200));
}
