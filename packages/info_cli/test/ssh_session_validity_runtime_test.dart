import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

/// A temporary, key-only server bound to loopback. No user's SSH files or
/// existing server are read or changed. Both keys and trust are synthetic.
class _SshServer {
  _SshServer(this.root, this.port, this.process, this.logs);
  final Directory root;
  final int port;
  final Process process;
  final List<String> logs;
  static Future<_SshServer> start() async {
    final created = await Directory.systemTemp.createTemp(
      'ssh-session-native-',
    );
    final root = Directory(await created.resolveSymbolicLinks());
    Process? server;
    try {
      for (final name in ['host', 'client']) {
        final result = await Process.run('/usr/bin/ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-C',
          'synthetic-local-test',
          '-f',
          '${root.path}/$name',
        ]);
        if (result.exitCode != 0) {
          throw StateError('Synthetic key generation failed');
        }
      }
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final user = Platform.environment['USER']!;
      final config = File('${root.path}/sshd_config');
      await config.writeAsString('''Port $port
ListenAddress 127.0.0.1
HostKey ${root.path}/host
PidFile ${root.path}/sshd.pid
AuthorizedKeysFile ${root.path}/client.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
AllowUsers $user
LogLevel ERROR
''');
      server = await Process.start('/usr/sbin/sshd', [
        '-D',
        '-e',
        '-f',
        config.path,
      ]);
      final logs = <String>[];
      void append(String text) {
        if (logs.length < 20) logs.add(text);
      }

      server.stdout.transform(utf8.decoder).listen(append);
      server.stderr.transform(utf8.decoder).listen(append);
      var ended = false;
      unawaited(server.exitCode.then((_) => ended = true));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!ended && DateTime.now().isBefore(deadline)) {
        try {
          final socket = await Socket.connect(
            '127.0.0.1',
            port,
            timeout: const Duration(milliseconds: 100),
          );
          socket.destroy();
          return _SshServer(root, port, server, logs);
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      throw StateError(
        'Local synthetic SSH server unavailable: ${logs.join()}',
      );
    } catch (_) {
      server?.kill();
      if (server != null) await server.exitCode;
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<int>> get key => File('${root.path}/client').readAsBytes();
  Future<List<int>> get trust async {
    final key = (await File(
      '${root.path}/host.pub',
    ).readAsString()).split(' ').take(2).join(' ');
    return utf8.encode('[127.0.0.1]:$port $key\n');
  }

  List<Object?> argv({bool slow = false}) => [
    '-T',
    '-o',
    'BatchMode=yes',
    '-i',
    {'file': 'token'},
    '-p',
    '$port',
    '${Platform.environment['USER']}@127.0.0.1',
    if (slow) ...['/bin/sleep', '2'] else '/usr/bin/true',
  ];
  Future<void> close() async {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
    await root.delete(recursive: true);
  }
}

void main() {
  for (final ending in ['revoke', 'chat-end']) {
    test(
      'real Mac SSH session grant crosses the old deadline; $ending stops new uses without terminating an established command',
      () async {
        final server = await _SshServer.start();
        addTearDown(server.close);
        var now = DateTime.now().toUtc();
        final h = await RuntimeHarness.create(
          fileBytes: await server.key,
          executablePath: '/usr/bin/ssh',
          inspectTool: true,
          enableReusableCredentialUse: true,
          clock: () => now,
        );
        addTearDown(h.close);
        await h.service.owner.configureSshKnownHosts(
          'Synthetic loopback host',
          await server.trust,
        );
        final caps = await h.client.execute({'command': 'capabilities'});
        expect(
          caps['capabilities'],
          contains('credential-ssh-session-validity.v1'),
        );
        final request = await h.approve(
          receiver: 'ssh_identity',
          protocolVersion: 2,
          argv: server.argv(),
          lifetime: null,
        );
        final approved = h.service.owner.credentialUseRequests.single;
        Map<String, dynamic> operation(String id, {bool slow = false}) => {
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': request,
          'operationId': id,
          'launch': <String, dynamic>{
            ...approved.toRequestInputJson()['launch'] as Map,
            'argv': server.argv(slow: slow),
          },
        };
        final first = await h.client.execute(operation('first'));
        expect(first['status'], 'accepted', reason: jsonEncode(first));
        await h.client.drainCredentialExecutions();
        final firstState = await h.client.execute({
          'command': 'execution-status',
          'executionId': first['executionId'],
        });
        expect(firstState['exitCode'], 0, reason: jsonEncode(firstState));
        await h.waitForMaterialCleanup(first['executionId'] as String);
        now = now.add(const Duration(days: 2));
        final status = await h.client.execute({
          'command': 'status',
          'requestId': request,
        });
        final validity = (status['decision'] as Map)['credentialUse'] as Map;
        expect(validity['validity'], 'session');
        expect(validity['expiresAt'], isNull);
        expect(validity['state'], 'available');
        expect(validity['sessionId'], isNotEmpty);
        final second = await h.client.execute(
          operation('long-second', slow: true),
        );
        expect(second['status'], 'accepted', reason: jsonEncode(second));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        Map<String, dynamic> live;
        do {
          live = await h.client.execute({
            'command': 'execution-status',
            'executionId': second['executionId'],
          });
          if (live['executionState'] == 'running') break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        } while (DateTime.now().isBefore(deadline));
        expect(live['executionState'], 'running', reason: jsonEncode(live));
        if (ending == 'revoke') {
          await h.service.owner.revokeCredentialUse(request);
        } else {
          h.service.agent.endSession(h.client.sessionSecret!);
        }
        final blocked = await h.client.execute(operation('blocked-third'));
        expect(
          blocked['errorCode'],
          ending == 'revoke' ? 'grant_revoked' : 'session_required',
        );
        await h.client.drainCredentialExecutions();
        final finalExecution = h.service.owner.credentialExecutions.singleWhere(
          (e) => e.id == second['executionId'],
        );
        expect(finalExecution.state, 'exited');
        expect(finalExecution.exitCode, 0);
        expect(h.service.owner.credentialExecutions, hasLength(2));
        expect(
          h.service.owner.credentialUseRequests.single.credentialValidity,
          CredentialUseValidity.session,
        );
        expect(
          h.service.owner.credentialGrantState(
            h.service.owner.credentialUseRequests.single,
          ),
          'revoked',
        );
      },
      skip: !Platform.isMacOS,
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
