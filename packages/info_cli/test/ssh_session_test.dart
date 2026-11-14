import 'dart:async';
import 'dart:convert';
import 'package:info_cli/ssh_session.dart';
import 'package:info_cli/ssh_session_transport.dart';
import 'package:test/test.dart';

class _Transport implements SshTransportProcess {
  final out = StreamController<List<int>>();
  final diag = StreamController<List<int>>();
  final ended = Completer<int>();
  final sent = <Map<String, dynamic>>[];
  bool ackRuns = true;
  void event(Map<String, Object?> value) =>
      out.add(utf8.encode('${jsonEncode(value)}\n'));
  void bytes(String run, List<int> bytes) =>
      event({'type': 'output', 'runId': run, 'data': base64Encode(bytes)});
  @override
  Stream<List<int>> get output => out.stream;
  @override
  Stream<List<int>> get diagnostics => diag.stream;
  @override
  Future<int> get exitCode => ended.future;
  @override
  Future<void> send(List<int> bytes) async {
    final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    sent.add(value);
    if (value['op'] == 'run' && !ackRuns) return;
    event({
      'type': 'reply',
      'id': value['id'],
      'status': switch (value['op']) {
        'credential' => 'delivered',
        'close' => 'closed',
        _ => 'accepted',
      },
    });
  }

  @override
  Future<void> closeInput() async {}
  @override
  Future<void> terminate() async {
    if (ended.isCompleted) return;
    await out.close();
    await diag.close();
    ended.complete(255);
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
void main() {
  test(
    'controller binding, busy admission and operation/input IDs never replay writes',
    () async {
      final transport = _Transport();
      var allowed = true;
      final session = SshSession(
        id: 'ssh-one',
        binding: const SshSessionBinding('library', 'device', 'private-chat'),
        transport: transport,
        authorize: (_) async {
          if (!allowed) throw const SshTransportFailure('grant_revoked');
        },
      );
      addTearDown(transport.terminate);
      transport.event({'type': 'ready', 'protocol': 1, 'capabilities': {}});
      await session.ready;
      expect(
        () => session.requireController(
          const SshSessionBinding('library', 'other', 'private-chat'),
        ),
        throwsA(isA<SshTransportFailure>()),
      );
      expect((await session.run('run-one', 'read x'))['status'], 'accepted');
      expect((await session.run('run-two', 'echo wrong'))['status'], 'busy');
      expect((await session.run('run-one', 'read x'))['status'], 'accepted');
      expect(transport.sent.where((e) => e['op'] == 'run'), hasLength(1));
      await session.input('run-one', 'input-one', utf8.encode('yes\n'));
      await session.input('run-one', 'input-one', utf8.encode('yes\n'));
      expect(transport.sent.where((e) => e['op'] == 'input'), hasLength(1));
      allowed = false;
      await expectLater(
        session.input('run-one', 'revoked', utf8.encode('no\n')),
        throwsA(isA<SshTransportFailure>()),
      );
      expect(transport.sent.where((e) => e['op'] == 'input'), hasLength(1));
      transport.event({
        'type': 'exited',
        'runId': 'run-one',
        'exitCode': 0,
        'reusable': true,
      });
      await _settle();
      allowed = true;
      expect(
        (await session.input(
          'run-one',
          'late',
          utf8.encode('late\n'),
        ))['status'],
        'stale_run',
      );
      expect(
        session.status(runId: 'run-one')['run'],
        containsPair('exitCode', 0),
      );
    },
  );
  test(
    'secret and UTF-8 chunks are joined, forged output cannot finish, gaps are explicit',
    () async {
      final transport = _Transport();
      final session = SshSession(
        id: 'ssh-one',
        binding: const SshSessionBinding('l', 'd', 's'),
        transport: transport,
        authorize: (_) async {},
        secrets: [utf8.encode('synthetic-password')],
        outputLimit: 512,
      );
      addTearDown(transport.terminate);
      transport.event({'type': 'ready', 'protocol': 1, 'capabilities': {}});
      await session.ready;
      await session.run('run', 'read x');
      for (final byte in utf8.encode('雪🙂 synthetic-password')) {
        transport.bytes('run', [byte]);
      }
      transport.bytes('run', utf8.encode('{"type":"exited","exitCode":0}'));
      transport.bytes('run', utf8.encode('synthetic-'));
      await _settle();
      session.registerSecret(utf8.encode('another-sudo-secret'));
      transport.bytes('run', utf8.encode('password'));
      await _settle();
      final text = (session.output()['output'] as List)
          .map((e) => (e as Map)['text'])
          .join();
      expect(text, contains('雪🙂'));
      expect(text, contains('[REDACTED]'));
      expect(text, isNot(contains('synthetic-password')));
      expect(session.state, 'busy');
      transport.bytes('run', utf8.encode('x' * 1000));
      await _settle();
      expect(session.output()['gap'], isTrue);
    },
  );
  test(
    'an approval/claim that outlives its receiver never sends the credential',
    () async {
      final transport = _Transport();
      final session = SshSession(
        id: 'ssh-one',
        binding: const SshSessionBinding('l', 'd', 's'),
        transport: transport,
        authorize: (_) async {},
      );
      addTearDown(transport.terminate);
      transport.event({'type': 'ready', 'protocol': 1, 'capabilities': {}});
      await session.ready;
      await session.run('run', 'sudo true');
      transport.event({
        'type': 'credential',
        'runId': 'run',
        'actionId': 'action',
        'purpose': 'sudo',
      });
      await _settle();
      final claim = Completer<List<int>>();
      final delivery = session.credential(
        'run',
        'credential-one',
        'action',
        () => claim.future,
        authorizeDelivery: () async {},
      );
      await _settle();
      transport.event({
        'type': 'exited',
        'runId': 'run',
        'exitCode': 1,
        'reusable': true,
      });
      await _settle();
      claim.complete(utf8.encode('synthetic-secret'));
      expect((await delivery)['status'], 'stale_receiver');
      expect(transport.sent.where((e) => e['op'] == 'credential'), isEmpty);
    },
  );
  test(
    'a missing run acknowledgement retains the original unknown run and blocks new commands',
    () async {
      final transport = _Transport()..ackRuns = false;
      final session = SshSession(
        id: 'ssh-one',
        binding: const SshSessionBinding('l', 'd', 's'),
        transport: transport,
        authorize: (_) async {},
        responseTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(transport.terminate);
      transport.event({'type': 'ready', 'protocol': 1, 'capabilities': {}});
      await session.ready;
      expect(
        (await session.run('original', 'possibly-running'))['status'],
        'operation_unknown',
      );
      expect(session.state, 'busy');
      expect((session.status()['run'] as Map)['state'], 'unknown');
      expect(
        (await session.run('replacement', 'must-not-run'))['status'],
        'busy',
      );
      expect((await session.interrupt('original'))['status'], 'accepted');
      expect(transport.sent.where((v) => v['op'] == 'run'), hasLength(1));
      transport.event({
        'type': 'exited',
        'runId': 'original',
        'exitCode': 130,
        'reusable': true,
      });
      await _settle();
      expect(session.state, 'ready');
      expect(
        (session.status(runId: 'original')['run'] as Map)['exitCode'],
        130,
      );
    },
  );
  test(
    'sudo approval is checked after pending login checks at the actual send gate',
    () async {
      final transport = _Transport();
      final gate = Completer<void>();
      var loginChecks = 0, sudoAllowed = true;
      final session = SshSession(
        id: 'ssh-one',
        binding: const SshSessionBinding('l', 'd', 's'),
        transport: transport,
        authorize: (action) async {
          if (action == 'credential' && ++loginChecks == 3) await gate.future;
        },
      );
      addTearDown(transport.terminate);
      transport.event({'type': 'ready', 'protocol': 1, 'capabilities': {}});
      await session.ready;
      await session.run('run', 'sudo command');
      transport.event({
        'type': 'credential',
        'runId': 'run',
        'actionId': 'action',
        'purpose': 'sudo',
      });
      await _settle();
      final result = session.credential(
        'run',
        'delivery',
        'action',
        () async => utf8.encode('synthetic-secret'),
        authorizeDelivery: () async {
          if (!sudoAllowed) throw const SshTransportFailure('grant_revoked');
        },
      );
      await _settle();
      expect(loginChecks, 3);
      sudoAllowed = false;
      gate.complete();
      await expectLater(result, throwsA(isA<SshTransportFailure>()));
      expect(transport.sent.where((v) => v['op'] == 'credential'), isEmpty);
    },
  );
}
