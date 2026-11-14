@TestOn('windows || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:info_cli/ssh_session_launch.dart';
import 'package:info_cli/ssh_session_macos.dart';
import 'package:info_cli/ssh_session_transport.dart';
import 'package:info_cli/ssh_session_windows.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final helper = Platform.environment['CHIYO_SSH_TEST_HELPER'];
  final python = Platform.environment['CHIYO_SSH_AUTH_TEST_PYTHON'];
  test(
    'pinned login options reject keyboard-interactive with a password-shaped prompt',
    () async {
      final root = await Directory.systemTemp.createTemp('ssh-auth-');
      addTearDown(() => root.delete(recursive: true));
      final fixture = await Process.start(python!, [
        '../../scripts/qa/ssh-session-fixture/keyboard_interactive.py',
        root.path,
      ]);
      unawaited(fixture.stderr.drain<void>());
      addTearDown(() async {
        await fixture.stdin.close();
        expect(await fixture.exitCode.timeout(const Duration(seconds: 5)), 0);
      });
      final facts =
          jsonDecode(
                await fixture.stdout
                    .transform(utf8.decoder)
                    .transform(const LineSplitter())
                    .first
                    .timeout(const Duration(seconds: 10)),
              )
              as Map<String, dynamic>;
      final empty = await File('${root.path}/empty').writeAsString('');
      final launcher = Platform.isWindows
          ? WindowsSshTransportLauncher(helperPath: helper!)
          : MacOsSshTransportLauncher(helperPath: helper!);
      var challenges = 0;
      final launch = sshSessionLaunch(
        target: SshSessionTarget(
          host: '127.0.0.1',
          port: facts['port'] as int,
          user: 'fixture',
          authentication: 'password',
          credentialUse: 'login',
          validity: 'session',
        ),
        executable: Platform.isWindows
            ? '${Platform.environment['SystemRoot']}\\System32\\OpenSSH\\ssh.exe'
            : '/usr/bin/ssh',
        knownHostsPath: facts['knownHosts'] as String,
        emptyConfigPath: empty.path,
        onLoginChallenge: (_) async {
          challenges++;
          return null; // The fixture never receives credential material.
        },
      );
      Future<void> collect(SshTransportLaunch config) async {
        final transport = await launcher.start(config);
        addTearDown(transport.terminate);
        final output = transport.output.drain<void>();
        final diagnostics = transport.diagnostics.drain<void>();
        expect(
          await transport.exitCode.timeout(const Duration(seconds: 10)),
          255,
        );
        await Future.wait([output, diagnostics]);
      }

      // Positive control proves this fixture emits the indistinguishable text.
      // No credential is returned, even for this deliberately permissive probe.
      await collect(
        SshTransportLaunch(
          executable: launch.executable,
          arguments: launch.arguments
              .map(
                (argument) => switch (argument) {
                  '-oKbdInteractiveAuthentication=no' =>
                    '-oKbdInteractiveAuthentication=yes',
                  '-oPreferredAuthentications=password' =>
                    '-oPreferredAuthentications=keyboard-interactive',
                  _ => argument,
                },
              )
              .toList(),
          environment: launch.environment,
          onLoginChallenge: launch.onLoginChallenge,
        ),
      );
      expect(challenges, 1);
      expect(await File('${root.path}/attempts.json').readAsString(), '1');
      challenges = 0;
      await collect(launch);
      expect(challenges, 0);
      expect(await File('${root.path}/attempts.json').readAsString(), '1');
    },
    skip: helper == null || python == null
        ? 'Requires an explicitly built native helper and isolated Paramiko.'
        : false,
  );
}
