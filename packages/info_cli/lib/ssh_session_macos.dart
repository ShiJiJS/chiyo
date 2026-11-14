import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

import 'ssh_session_transport.dart';

/// The bundled native broker verifies Unix peer identity and the exact SSH
/// child before forwarding one authentication challenge over private pipes.
class MacOsSshTransportLauncher implements SshTransportLauncher {
  const MacOsSshTransportLauncher({required this.helperPath});
  final String helperPath;
  @override
  Future<SshTransportProcess> start(SshTransportLaunch launch) async {
    final process = await Process.start(
      helperPath,
      const [],
      includeParentEnvironment: false,
      environment: {'PATH': '/usr/bin:/bin', 'TMPDIR': '/tmp'},
    );
    final identity = CredentialProcessIdentity.capture(process.pid);
    try {
      if (identity == null) {
        throw const SshTransportFailure('process_identity_unavailable');
      }
      await launch.onProcessCreated?.call(process.pid, identity.value);
    } on Object {
      process.kill();
      await process.stdin.close();
      rethrow;
    } finally {
      identity?.close();
    }
    final result = _MacProcess(process, launch);
    result.initialize();
    await result.write({
      'executable': launch.executable,
      'arguments': launch.arguments,
      'environment': launch.environment,
    });
    await result.started.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        throw const SshTransportFailure('transport_unavailable');
      },
    );
    return result;
  }
}

class _MacProcess implements SshTransportProcess {
  _MacProcess(this.process, this.launch);
  final Process process;
  final SshTransportLaunch launch;
  final started = Completer<void>();
  final _output = StreamController<List<int>>();
  final _diagnostics = StreamController<List<int>>();
  final _exit = Completer<int>();
  Future<void> _writing = Future.value();
  bool _ended = false;
  int? _reportedExit;
  void initialize() {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              if (line.length > 262144) throw const FormatException();
              final value = jsonDecode(line) as Map<String, dynamic>;
              switch (value['type']) {
                case 'started':
                  if (!started.isCompleted) started.complete();
                case 'output':
                  _output.add(base64Decode(value['data'] as String));
                case 'diagnostic':
                  _diagnostics.add(base64Decode(value['data'] as String));
                case 'challenge':
                  unawaited(_challenge(value));
                case 'exit':
                  _reportedExit = value['exitCode'] as int;
                case 'failure':
                  _fail();
                default:
                  throw const FormatException();
              }
            } on Object {
              _fail();
            }
          },
          onError: (_) => _fail(),
          onDone: () async {
            final code = await process.exitCode;
            _ended = true;
            if (!started.isCompleted) {
              started.completeError(
                const SshTransportFailure('transport_unavailable'),
              );
            }
            await _output.close();
            await _diagnostics.close();
            if (!_exit.isCompleted) _exit.complete(_reportedExit ?? code);
          },
        );
    // Native diagnostics never bypass the common secret filter.
    process.stderr.listen((bytes) {
      if (!_ended) _diagnostics.add(bytes);
    }, onError: (_) {});
  }

  void _fail() {
    process.kill();
  }

  Future<void> _challenge(Map<String, dynamic> value) async {
    List<int>? secret;
    try {
      secret = await launch.onLoginChallenge(
        SshLoginChallenge(
          challengeId: value['challengeId'] as String,
          processId: value['processId'] as int,
          processIdentity: value['processIdentity'] as String,
          category: value['category'] as String,
        ),
      );
    } on Object {
      /* Refuse. Never retry or include exception text. */
    }
    if (_ended) return;
    await write({
      'type': 'credential',
      'challengeId': value['challengeId'],
      if (secret != null) 'data': base64Encode(secret),
    });
  }

  Future<void> write(Map<String, Object?> value) {
    final next = _writing.then((_) async {
      if (_ended) throw const SshTransportFailure('transport_closed');
      process.stdin.writeln(jsonEncode(value));
      await process.stdin.flush();
    });
    _writing = next.then((_) {}, onError: (_) {});
    return next;
  }

  @override
  Stream<List<int>> get output => _output.stream;
  @override
  Stream<List<int>> get diagnostics => _diagnostics.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  Future<void> send(List<int> bytes) =>
      write({'type': 'send', 'data': base64Encode(bytes)});
  @override
  Future<void> closeInput() => write({'type': 'close'});
  @override
  Future<void> terminate() => write({'type': 'terminate'});
}
