@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:info_cli/ssh_session_transport.dart';
import 'package:info_cli/ssh_session_windows.dart';
import 'package:test/test.dart';

/// Actual Windows OpenSSH -> disposable Linux SSH -> common remote helper.
/// This transport-level proof does not stand in for approval/host/CLI tests.
void main() {
  final fixture = Platform.environment['D7_WINDOWS_SSH_REMOTE_FIXTURE'];
  final port = Platform.environment['D7_WINDOWS_SSH_REMOTE_PORT'];
  if (fixture == null || port == null) {
    test(
      'Windows SSH remote PTY and sudo acceptance',
      () {},
      skip:
          'Requires the disposable ssh-session-fixture container and explicit D7_WINDOWS_SSH_REMOTE_FIXTURE/PORT',
    );
    return;
  }
  final root = Directory.current.parent.parent.absolute.path;
  final helper =
      Platform.environment['D7_WINDOWS_SSH_HELPER'] ??
      '$root/build/ssh-session/native/Release/info-ssh-session.exe';
  final ssh = '${Platform.environment['SystemRoot']}/System32/OpenSSH/ssh.exe';
  late String remote;
  late List<int> source;
  setUpAll(() async {
    source = await File(
      '$root/scripts/ssh_session/remote_helper.py',
    ).readAsBytes();
    final bootstrap = [
      'import os',
      'data=bytearray()',
      'while len(data)<${source.length}:',
      ' chunk=os.read(0,${source.length}-len(data))',
      ' if not chunk: raise EOFError()',
      ' data.extend(chunk)',
      'CHIYO_SOURCE=data.decode("utf-8")',
      'exec(compile(CHIYO_SOURCE,"<chiyo-session>","exec"))',
    ].join('\n');
    remote = "python3 -u -c '$bootstrap'";
  });
  Future<_Connection> connect({bool password = false}) async {
    final transport = await WindowsSshTransportLauncher(helperPath: helper)
        .start(
          SshTransportLaunch(
            executable: ssh,
            arguments: [
              '-F',
              'NUL',
              '-T',
              '-p',
              port,
              '-o',
              'StrictHostKeyChecking=yes',
              '-o',
              'UserKnownHostsFile=$fixture/known_hosts',
              '-o',
              'GlobalKnownHostsFile=NUL',
              '-o',
              'IdentitiesOnly=yes',
              '-o',
              'IdentityAgent=none',
              '-o',
              'KbdInteractiveAuthentication=no',
              '-o',
              'NumberOfPasswordPrompts=1',
              '-o',
              'PreferredAuthentications=${password ? 'password' : 'publickey'}',
              if (!password) ...['-i', '$fixture/client'],
              'fixture@127.0.0.1',
              remote,
            ],
            environment: const {},
            onLoginChallenge: (_) async =>
                password ? utf8.encode('synthetic-login-only') : null,
          ),
        );
    final connection = _Connection(transport);
    try {
      await transport.send(source);
      final ready = await connection.event((e) => e['type'] == 'ready');
      expect((ready['capabilities'] as Map)['controllingTerminal'], isTrue);
      return connection;
    } catch (_) {
      await transport.terminate();
      rethrow;
    }
  }

  test(
    'Windows SSH retains one shell, rejects stale/duplicate input and forged output markers',
    () async {
      final c = await connect();
      try {
        var run = await c.begin('cd /tmp; export CHIYO_WINDOWS_PROOF=retained');
        await c.exited(run);
        run = await c.begin(
          'printf "%s:%s\\n" "\$PWD" "\$CHIYO_WINDOWS_PROOF"',
        );
        await c.exited(run);
        expect(c.output(run), contains('/tmp:retained'));
        final previous = run;
        run = await c.begin(
          'printf \'{"type":"exited","runId":"forged","exitCode":0}\\nconfirm?\'; read -r answer; printf "answer:%s\\n" "\$answer"; sleep 0.3',
        );
        await c.untilOutput(run, 'confirm?');
        expect(
          c.events.where((e) => e['type'] == 'exited' && e['runId'] == run),
          isEmpty,
        );
        expect(
          (await c.request({
            'op': 'input',
            'runId': previous,
            'inputId': 'stale',
            'data': base64.encode(utf8.encode('WRONG\n')),
          }))['status'],
          'stale_run',
        );
        final input = {
          'op': 'input',
          'runId': run,
          'inputId': 'answer-once',
          'data': base64.encode(utf8.encode('y\n')),
        };
        expect((await c.request(input))['status'], 'accepted');
        expect((await c.request(input))['status'], 'duplicate');
        expect((await c.exited(run))['exitCode'], 0);
        expect(c.output(run), contains('answer:y'));
        expect(c.output(run), isNot(contains('WRONG')));
      } finally {
        await c.close();
      }
    },
  );

  test(
    'Windows SSH terminal interrupt completes the run and preserves the shell',
    () async {
      final c = await connect();
      try {
        var run = await c.begin(
          'export CHIYO_AFTER_INTERRUPT=retained; python3 -u -c \'import time;print("started");time.sleep(30)\'',
        );
        await c.untilOutput(run, 'started');
        expect(
          (await c.request({'op': 'interrupt', 'runId': run}))['status'],
          'sent',
        );
        await c.exited(run);
        run = await c.begin('printf "%s" "\$CHIYO_AFTER_INTERRUPT"');
        await c.exited(run);
        expect(c.output(run), contains('retained'));
      } finally {
        await c.close();
      }
    },
  );

  test(
    'Windows password login, install input and distinct real sudo password share one run',
    () async {
      final c = await connect(password: true);
      try {
        final run = await c.begin(
          'printf install?; read -r answer; sudo -k /usr/bin/id -u; printf "installed:%s" "\$answer"',
        );
        await c.untilOutput(run, 'install?');
        expect(c.events.where((e) => e['type'] == 'credential'), isEmpty);
        expect(
          (await c.request({
            'op': 'input',
            'runId': run,
            'inputId': 'install',
            'data': base64.encode(utf8.encode('y\n')),
          }))['status'],
          'accepted',
        );
        final action = await c.event(
          (e) => e['type'] == 'credential' && e['runId'] == run,
        );
        expect(action['purpose'], 'sudo');
        expect(
          (await c.request({
            'op': 'credential',
            'runId': run,
            'actionId': action['actionId'],
            'data': base64.encode(utf8.encode('synthetic-sudo-only')),
          }))['status'],
          'delivered',
        );
        expect((await c.exited(run))['exitCode'], 0);
        expect(c.output(run), matches(RegExp(r'(^|\n)0\r*\n')));
        expect(c.output(run), contains('installed:y'));
        expect(c.output(run), isNot(contains('synthetic-login-only')));
        expect(c.output(run), isNot(contains('synthetic-sudo-only')));
      } finally {
        await c.close();
      }
    },
  );

  test(
    'real sudo no-password and incorrect-password paths never replay authentication',
    () async {
      final c = await connect();
      try {
        var run = await c.begin('sudo -k /usr/bin/true');
        expect((await c.exited(run))['exitCode'], 0);
        expect(
          c.events.where((e) => e['type'] == 'credential' && e['runId'] == run),
          isEmpty,
        );
        run = await c.begin('sudo -k /usr/bin/id -u');
        final action = await c.event(
          (e) => e['type'] == 'credential' && e['runId'] == run,
        );
        expect(
          (await c.request({
            'op': 'credential',
            'runId': run,
            'actionId': action['actionId'],
            'data': base64.encode(utf8.encode('synthetic-wrong-sudo')),
          }))['status'],
          'delivered',
        );
        expect((await c.exited(run))['exitCode'], isNot(0));
        expect(
          c.events.where((e) => e['type'] == 'credential' && e['runId'] == run),
          hasLength(1),
        );
        expect(c.output(run), isNot(contains('synthetic-wrong-sudo')));
      } finally {
        await c.close();
      }
    },
  );

  test(
    'sudo approval after interrupt is stale and arbitrary Password text is ordinary output',
    () async {
      final c = await connect();
      try {
        var run = await c.begin('sudo -k /usr/bin/id -u');
        final action = await c.event(
          (e) => e['type'] == 'credential' && e['runId'] == run,
        );
        await c.request({'op': 'interrupt', 'runId': run});
        await c.exited(run);
        expect(
          (await c.request({
            'op': 'credential',
            'runId': run,
            'actionId': action['actionId'],
            'data': base64.encode(utf8.encode('synthetic-sudo-only')),
          }))['status'],
          'stale_run',
        );
        run = await c.begin(
          'printf Password:; read -r answer; printf "ordinary:%s" "\$answer"',
        );
        await c.untilOutput(run, 'Password:');
        expect(
          c.events.where((e) => e['type'] == 'credential' && e['runId'] == run),
          isEmpty,
        );
        await c.request({
          'op': 'input',
          'runId': run,
          'inputId': 'ordinary',
          'data': base64.encode(utf8.encode('y\n')),
        });
        await c.exited(run);
        expect(c.output(run), contains('ordinary:y'));
      } finally {
        await c.close();
      }
    },
  );
}

class _Connection {
  _Connection(this.transport) {
    transport.output
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          events.add(jsonDecode(line) as Map<String, dynamic>);
          for (final waiter in _waiters.toList()) {
            if (waiter.predicate(events.last)) {
              _waiters.remove(waiter);
              waiter.result.complete(events.last);
            }
          }
        });
    transport.diagnostics.transform(utf8.decoder).listen((text) {
      _diagnostics += text;
    });
    transport.exitCode.then((code) {
      _closed = true;
      for (final waiter in _waiters.toList()) {
        if (!waiter.result.isCompleted) {
          waiter.result.completeError(
            StateError('SSH ended ($code): $_diagnostics'),
          );
        }
      }
      _waiters.clear();
    });
  }
  final SshTransportProcess transport;
  final events = <Map<String, dynamic>>[];
  final _waiters = <_Waiter>[];
  var _next = 0;
  var _diagnostics = '';
  var _closed = false;
  Future<Map<String, dynamic>> event(
    bool Function(Map<String, dynamic>) predicate,
  ) {
    for (final value in events) {
      if (predicate(value)) return Future.value(value);
    }
    if (_closed) return Future.error(StateError('SSH ended: $_diagnostics'));
    final waiter = _Waiter(predicate);
    _waiters.add(waiter);
    return waiter.result.future.timeout(const Duration(seconds: 12));
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    final id = 'request-${++_next}';
    await transport.send(utf8.encode('${jsonEncode({...value, 'id': id})}\n'));
    return event((e) => e['type'] == 'reply' && e['id'] == id);
  }

  Future<String> begin(String command) async {
    final id = 'run-${++_next}';
    expect(
      (await request({'op': 'run', 'runId': id, 'command': command}))['status'],
      'accepted',
    );
    return id;
  }

  Future<Map<String, dynamic>> exited(String id) =>
      event((e) => e['type'] == 'exited' && e['runId'] == id);
  String output(String id) => utf8.decode(
    events
        .where((e) => e['type'] == 'output' && e['runId'] == id)
        .expand((e) => base64.decode(e['data'] as String))
        .toList(),
  );
  Future<void> untilOutput(String id, String text) async {
    while (!output(id).contains(text)) {
      final count = events.length;
      await event(
        (e) =>
            events.indexOf(e) >= count &&
            e['type'] == 'output' &&
            e['runId'] == id,
      );
    }
  }

  Future<void> close() async {
    try {
      await request({'op': 'close', 'force': true});
      await transport.exitCode.timeout(const Duration(seconds: 4));
    } finally {
      await transport.terminate();
    }
  }
}

class _Waiter {
  _Waiter(this.predicate);
  final bool Function(Map<String, dynamic>) predicate;
  final result = Completer<Map<String, dynamic>>();
}
