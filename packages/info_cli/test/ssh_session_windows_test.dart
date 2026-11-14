@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:info_cli/ssh_session_transport.dart';
import 'package:info_cli/ssh_session_windows.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent.absolute.path;
  final ssh = '${Platform.environment['SystemRoot']}/System32/OpenSSH/ssh.exe';
  final helper =
      Platform.environment['D7_WINDOWS_SSH_HELPER'] ??
      '$root/build/ssh-session/native/Release/info-ssh-session.exe';
  final python =
      Platform.environment['D7_WINDOWS_SSH_PYTHON'] ??
      '$root/build/ssh-session/qa-venv/Scripts/python.exe';
  final fixtureDirectory = Directory(
    '$root/build/ssh-session/fixture-${DateTime.now().microsecondsSinceEpoch}',
  );
  late Process fixture;
  late Map<String, dynamic> facts;
  final active = <SshTransportProcess>[];

  setUpAll(() async {
    expect(
      await File(helper).exists(),
      isTrue,
      reason: 'Build scripts/build-windows-ssh-session.ps1 first',
    );
    expect(
      await File(python).exists(),
      isTrue,
      reason: 'Prepare isolated QA Python with paramiko==5.1.0',
    );
    fixture = await Process.start(python, [
      '$root/packages/info_cli/windows/ssh_session/test_fixture.py',
      fixtureDirectory.path,
      '--ssh-keygen',
      '${File(ssh).parent.path}/ssh-keygen.exe',
    ]);
    unawaited(fixture.stderr.drain<void>());
    facts =
        jsonDecode(
              await fixture.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .first
                  .timeout(const Duration(seconds: 15)),
            )
            as Map<String, dynamic>;
  });
  tearDown(() async {
    for (final transport in active) {
      await transport.terminate();
    }
    active.clear();
  });
  tearDownAll(() async {
    await fixture.stdin.close();
    expect(await fixture.exitCode.timeout(const Duration(seconds: 8)), 0);
    if (await fixtureDirectory.exists())
      await fixtureDirectory.delete(recursive: true);
  });

  Future<SshTransportProcess> start({
    bool password = false,
    String command = 'output',
    String? knownHosts,
    String? key,
    SshLoginChallengeHandler? challenge,
  }) async {
    final transport = await WindowsSshTransportLauncher(helperPath: helper)
        .start(
          SshTransportLaunch(
            executable: ssh,
            arguments: [
              '-F',
              'NUL',
              '-T',
              '-o',
              'StrictHostKeyChecking=yes',
              '-o',
              'UserKnownHostsFile=${knownHosts ?? facts['knownHosts']}',
              '-o',
              'GlobalKnownHostsFile=NUL',
              '-o',
              'IdentitiesOnly=yes',
              '-o',
              'IdentityAgent=none',
              '-o',
              'NumberOfPasswordPrompts=1',
              '-o',
              'ConnectTimeout=5',
              '-o',
              'PreferredAuthentications=${password ? 'password' : 'publickey'}',
              '-p',
              '${facts['port']}',
              if (!password) ...['-i', key ?? facts['key'] as String],
              'fixture@127.0.0.1',
              command,
            ],
            environment: const {},
            onLoginChallenge:
                challenge ?? (_) async => fail('Unexpected login challenge'),
          ),
        );
    active.add(transport);
    return transport;
  }

  Future<({int code, String output, String diagnostics})> collect(
    SshTransportProcess transport,
  ) async {
    final output = transport.output.transform(utf8.decoder).join();
    final diagnostics = transport.diagnostics.transform(utf8.decoder).join();
    final code = await transport.exitCode.timeout(const Duration(seconds: 15));
    return (code: code, output: await output, diagnostics: await diagnostics);
  }

  test(
    'actual Windows OpenSSH password uses one verified private challenge',
    () async {
      final seen = <SshLoginChallenge>[];
      final transport = await start(
        password: true,
        challenge: (challenge) async {
          seen.add(challenge);
          return utf8.encode('synthetic-login-password');
        },
      );
      final result = await collect(transport);
      expect(result.code, 0, reason: result.diagnostics);
      expect(result.output, 'fixture-output\n');
      expect(seen, hasLength(1));
      expect(seen.single.category, 'password');
      expect(seen.single.processId, greaterThan(0));
      expect(seen.single.processIdentity, matches(r'^\d+$'));
      expect(
        '${result.output}${result.diagnostics}',
        isNot(contains('synthetic-login-password')),
      );
    },
  );

  test(
    'actual key authentication and remote nonzero exit preserve result',
    () async {
      final result = await collect(await start(command: 'nonzero'));
    expect(result.code, 7, reason: result.diagnostics);
      expect(result.output, 'fixture-output\n');
    },
  );

  test(
    'strict host verification refuses unknown key before requesting a password',
    () async {
      final unknown = File('${fixtureDirectory.path}/unknown_hosts');
      await unknown.writeAsString('');
      final result = await collect(
        await start(password: true, knownHosts: unknown.path),
      );
      expect(result.code, 255);
      expect(result.diagnostics, contains('Host key verification failed'));
    },
  );

  test('incorrect password is attempted once and never replayed', () async {
    var challenges = 0;
    final result = await collect(
      await start(
        password: true,
        challenge: (_) async {
          challenges++;
          return utf8.encode('synthetic-wrong-password');
        },
      ),
    );
    expect(result.code, 255);
    expect(challenges, 1);
    expect(result.diagnostics, isNot(contains('synthetic-wrong-password')));
  });

  test(
    'key passphrase fails explicitly without receiving login credential',
    () async {
      final result = await collect(
        await start(key: facts['encryptedKey'] as String),
      );
      expect(result.code, 255);
      expect(result.diagnostics, contains('ssh_login_challenge_unsupported'));
    },
  );

  test(
    'byte streams survive UTF8 splitting, large output and channel EOF',
    () async {
      final transport = await start(command: 'echo');
      final result = collect(transport);
      final bytes = utf8.encode('中文输入\u001b[31m\r\n' * 12000);
      await transport.send(bytes.sublist(0, 1));
      await transport.send(bytes.sublist(1));
      await transport.closeInput();
      final observed = await result;
      expect(observed.code, 0);
      expect(observed.output, 'ready\n${utf8.decode(bytes)}');
    },
  );

  test('closing during pending authentication rejects a late secret', () async {
    final requested = Completer<void>();
    final reply = Completer<List<int>?>();
    var challenges = 0;
    final transport = await start(
      password: true,
      challenge: (_) {
        challenges++;
        requested.complete();
        return reply.future;
      },
    );
    final result = collect(transport);
    await requested.future.timeout(const Duration(seconds: 10));
    await transport.terminate();
    reply.complete(utf8.encode('synthetic-login-password'));
    final observed = await result;
    expect(observed.code, 255);
    expect(observed.output, isEmpty);
    expect(challenges, 1);
  });
}
