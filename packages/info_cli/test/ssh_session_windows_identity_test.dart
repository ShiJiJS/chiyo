@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:info_cli/ssh_session_transport.dart';
import 'package:info_cli/ssh_session_windows.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent.absolute.path;
  final helper =
      Platform.environment['D7_WINDOWS_SSH_HELPER'] ??
      '$root/build/ssh-session/native/Release/info-ssh-session.exe';
  final child = '${File(helper).parent.path}/ssh_session_test_child.exe';
  final copy = File(
    '$root/build/ssh-session/identity-${DateTime.now().microsecondsSinceEpoch}.exe',
  );
  setUpAll(() async {
    expect(
      await File(child).exists(),
      isTrue,
      reason: 'Build scripts/build-windows-ssh-session.ps1 -BuildTests first',
    );
    await File(helper).copy(copy.path);
  });
  tearDownAll(() async {
    if (await copy.exists()) await copy.delete();
  });

  Future<({int code, String output, String diagnostics, int challenges})> run(
    String mode,
  ) async {
    var challenges = 0;
    final transport = await WindowsSshTransportLauncher(helperPath: helper)
        .start(
          SshTransportLaunch(
            executable: File(child).absolute.path,
            arguments: [mode],
            environment: {'CHIYO_QA_HELPER_COPY': copy.path},
            onLoginChallenge: (_) async {
              challenges++;
              return utf8.encode('synthetic-login-password');
            },
          ),
        );
    try {
      final output = transport.output.transform(utf8.decoder).join();
      final diagnostics = transport.diagnostics.transform(utf8.decoder).join();
      final code = await transport.exitCode.timeout(
        const Duration(seconds: 10),
      );
      return (
        code: code,
        output: await output,
        diagnostics: await diagnostics,
        challenges: challenges,
      );
    } finally {
      await transport.terminate();
    }
  }

  test('owned child has no console window', () async {
    final result = await run('headless');
    expect(result.code, 0);
    expect(result.output, 'headless\n');
    expect(result.challenges, 0);
  });

  test(
    'verified direct helper receives the password without exposing it',
    () async {
      final result = await run('ask');
      expect(result.code, 0, reason: result.diagnostics);
      expect(result.output, 'accepted\n');
      expect(result.challenges, 1);
      expect(
        '${result.output}${result.diagnostics}',
        isNot(contains('synthetic-login-password')),
      );
    },
  );

  test(
    'a copied helper at another file identity cannot request a password',
    () async {
      final result = await run('copy');
      expect(result.code, isNot(0));
      expect(result.output, 'denied\n');
      expect(result.challenges, 0);
    },
  );

  test('a helper behind another parent cannot request a password', () async {
    final result = await run('relay');
    expect(result.code, isNot(0));
    expect(result.challenges, 0);
  });

  test(
    'arbitrary Password prompt never receives a managed login credential',
    () async {
      final result = await run('unsupported');
      expect(result.code, isNot(0));
      expect(result.challenges, 0);
      expect(result.diagnostics, contains('ssh_login_challenge_unsupported'));
    },
  );

  test('one authentication cannot request the password twice', () async {
    final result = await run('repeat');
    expect(result.code, isNot(0));
    expect(result.challenges, 1);
    expect(result.diagnostics, contains('ssh_login_challenge_repeated'));
  });
}
