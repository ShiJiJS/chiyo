@TestOn('windows || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:info_cli/ssh_session_launch.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final executable = Platform.isWindows
      ? '${Platform.environment['SystemRoot']}\\System32\\OpenSSH\\ssh.exe'
      : '/usr/bin/ssh';
  test(
    'real OpenSSH preserves config paths with spaces and literal percent',
    () async {
      final root = await Directory.systemTemp.createTemp('ssh config % ');
      addTearDown(() => root.delete(recursive: true));
      final config = await File('${root.path}/empty config').writeAsString('');
      final hosts = '${root.path}/known hosts';
      final key = '${root.path}/private key';
      final launch = sshSessionLaunch(
        target: SshSessionTarget(
          host: 'example.invalid',
          port: 22,
          user: 'fixture',
          authentication: 'publickey',
          credentialUse: 'login',
          validity: 'session',
        ),
        executable: executable,
        knownHostsPath: hosts,
        emptyConfigPath: config.path,
        privateKeyPath: key,
        onLoginChallenge: (_) async => null,
      );
      // -F and -i are native argv paths, not config values.
      expect(launch.arguments[launch.arguments.indexOf('-F') + 1], config.path);
      expect(launch.arguments[launch.arguments.indexOf('-i') + 1], key);
      final result = await Process.run(executable, ['-G', ...launch.arguments]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final output = const LineSplitter().convert(result.stdout as String);
      String normalized(String path) =>
          Platform.isWindows ? path.replaceAll('\\', '/') : path;
      expect(output, contains('userknownhostsfile ${normalized(hosts)}'));
      expect(
        output,
        contains('globalknownhostsfile ${normalized(config.path)}'),
      );
    },
    skip: !File(executable).existsSync() ? 'OpenSSH is unavailable' : false,
  );
}
