import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';

import 'ssh_session_transport.dart';

/// Windows OpenSSH runs in an owned background job. The bundled native helper
/// also serves ASKPASS through a per-launch ACL-restricted named pipe. It checks
/// the requesting process's executable identity, SSH parent and creation time.
class WindowsSshTransportLauncher implements SshTransportLauncher {
  WindowsSshTransportLauncher({String? helperPath})
    : helperPath =
          helperPath ??
          '${File(Platform.resolvedExecutable).parent.path}/info-ssh-session.exe';

  final String helperPath;

  @override
  Future<SshTransportProcess> start(SshTransportLaunch launch) async {
    if (!Platform.isWindows) {
      throw const SshTransportFailure('ssh_windows_required');
    }
    if (!File(helperPath).isAbsolute || !await File(helperPath).exists()) {
      throw const SshTransportFailure('ssh_windows_helper_missing');
    }
    if (!File(launch.executable).isAbsolute ||
        launch.arguments.any((arg) => arg.contains('\u0000')) ||
        launch.environment.entries.any(
          (entry) =>
              entry.key.isEmpty ||
              entry.key.contains(RegExp('[=\u0000]')) ||
              entry.value.contains('\u0000'),
        )) {
      throw const SshTransportFailure('ssh_launch_invalid');
    }
    final process = await Process.start(helperPath, const ['--broker']);
    CredentialProcessIdentity? identity;
    try {
      identity = CredentialProcessIdentity.capture(process.pid);
      if (identity == null) {
        throw const SshTransportFailure('process_identity_unavailable');
      }
      // The broker is blocked reading its first frame. Register this exact
      // consumer before it may start SSH or open managed authentication files.
      await launch.onProcessCreated?.call(process.pid, identity.value);
      if (CredentialProcessIdentity.isActive(process.pid, identity.value) !=
          true) {
        throw const SshTransportFailure('ssh_broker_identity_ended');
      }
    } on Object {
      process.kill();
      await process.stdin.close();
      await Future.wait([
        process.stdout.drain<void>(),
        process.stderr.drain<void>(),
        process.exitCode,
      ]);
      rethrow;
    } finally {
      identity?.close();
    }
    final transport = _WindowsSshTransport(process, launch.onLoginChallenge);
    try {
      await transport._write(
        1,
        utf8.encode(
          jsonEncode({
            'executable': launch.executable,
            'arguments': launch.arguments,
            'environment': launch.environment,
          }),
        ),
      );
      await transport._ready.future;
      return transport;
    } catch (_) {
      await transport.terminate();
      rethrow;
    }
  }
}

class _WindowsSshTransport implements SshTransportProcess {
  _WindowsSshTransport(this._process, this._challengeHandler) {
    _process.stdout.listen(
      _receive,
      onError: (_) => _fail('ssh_broker_io_failed'),
    );
    // The broker never writes secrets or OS errors to stderr. Keep this stream
    // drained, but do not expose unframed accidental diagnostics to callers.
    _process.stderr.drain<void>();
    _process.exitCode.then((_) {
      if (!_ready.isCompleted) {
        _ready.completeError(
          SshTransportFailure(_failure ?? 'ssh_broker_lost'),
        );
      }
      if (!_exit.isCompleted) _exit.complete(255);
      _ended = true;
      _output.close();
      _diagnostics.close();
    });
  }

  final Process _process;
  final SshLoginChallengeHandler _challengeHandler;
  final _ready = Completer<void>();
  final _exit = Completer<int>();
  final _output = StreamController<List<int>>();
  final _diagnostics = StreamController<List<int>>();
  final _pending = BytesBuilder(copy: false);
  Future<void> _writes = Future.value();
  bool _ended = false, _inputClosed = false, _challenged = false;
  String? _failure;
  Uint8List _buffer = Uint8List(0);

  @override
  Stream<List<int>> get output => _output.stream;
  @override
  Stream<List<int>> get diagnostics => _diagnostics.stream;
  @override
  Future<int> get exitCode => _exit.future;

  Future<void> _write(int type, List<int> bytes) {
    if (_ended) {
      return Future.error(const SshTransportFailure('ssh_transport_closed'));
    }
    if (bytes.length >= 1024 * 1024) {
      return Future.error(const SshTransportFailure('ssh_frame_too_large'));
    }
    final frame = Uint8List(bytes.length + 5);
    ByteData.sublistView(frame).setUint32(0, bytes.length + 1, Endian.little);
    frame[4] = type;
    frame.setRange(5, frame.length, bytes);
    final result = _writes.then((_) async {
      try {
        if (_ended) throw const SshTransportFailure('ssh_transport_closed');
        _process.stdin.add(frame);
        await _process.stdin.flush();
      } finally {
        frame.fillRange(0, frame.length, 0);
      }
    });
    _writes = result.catchError((Object _) {});
    return result;
  }

  void _receive(List<int> bytes) {
    if (_ended) return;
    _pending.add(_buffer);
    _pending.add(bytes);
    _buffer = _pending.takeBytes();
    var offset = 0;
    while (_buffer.length - offset >= 4) {
      final size = ByteData.sublistView(
        _buffer,
      ).getUint32(offset, Endian.little);
      if (size == 0 || size > 1024 * 1024) {
        _fail('ssh_broker_protocol_invalid');
        return;
      }
      if (_buffer.length - offset < size + 4) break;
      final type = _buffer[offset + 4];
      final payload = Uint8List.fromList(
        _buffer.sublist(offset + 5, offset + size + 4),
      );
      offset += size + 4;
      if (type == 0x10) {
        if (!_ready.isCompleted) _ready.complete();
      } else if (type == 0x11) {
        _output.add(payload);
      } else if (type == 0x12) {
        _diagnostics.add(payload);
      } else if (type == 0x13) {
        unawaited(_answer(payload));
      } else if (type == 0x14 && payload.length == 4) {
        if (!_exit.isCompleted) {
          _exit.complete(
            ByteData.sublistView(payload).getUint32(0, Endian.little),
          );
        }
      } else if (type == 0x15) {
        _fail(utf8.decode(payload, allowMalformed: true));
      } else {
        _fail('ssh_broker_protocol_invalid');
      }
    }
    _buffer = Uint8List.fromList(_buffer.sublist(offset));
  }

  Future<void> _answer(List<int> payload) async {
    List<int>? secret;
    Uint8List? response;
    try {
      final raw = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      if (_challenged || raw['category'] != 'password') {
        _fail('ssh_login_challenge_unsupported');
        return;
      }
      _challenged = true;
      final challenge = SshLoginChallenge(
        challengeId: raw['challengeId'] as String,
        processId: raw['processId'] as int,
        processIdentity: raw['processIdentity'] as String,
        category: raw['category'] as String,
      );
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(challenge.challengeId)) {
        _fail('ssh_broker_protocol_invalid');
        return;
      }
      secret = await _challengeHandler(challenge);
      if (_ended || _exit.isCompleted || _failure != null) return;
      if (secret != null &&
          (secret.length > 65536 ||
              secret.any(
                (b) => b == 0 || b == 10 || b == 13 || b < 0 || b > 255,
              ))) {
        _fail('ssh_login_response_invalid');
        return;
      }
      response = Uint8List(33 + (secret?.length ?? 0));
      response.setRange(0, 32, ascii.encode(challenge.challengeId));
      response[32] = secret == null ? 0 : 1;
      if (secret != null) response.setRange(33, response.length, secret);
      await _write(5, response);
    } catch (_) {
      _fail('ssh_login_response_failed');
    } finally {
      response?.fillRange(0, response.length, 0);
      // The handler retains ownership of its list (which may be immutable).
      // Only platform-owned copies are zeroed here.
    }
  }

  void _fail(String code) {
    _failure ??= code;
    if (!_ready.isCompleted) _ready.completeError(SshTransportFailure(code));
    if (!_diagnostics.isClosed) {
      _diagnostics.add(utf8.encode('$code\n'));
    }
    _process.kill();
  }

  @override
  Future<void> send(List<int> bytes) async {
    if (_inputClosed) throw const SshTransportFailure('ssh_input_closed');
    for (var offset = 0; offset < bytes.length; offset += 32768) {
      await _write(
        2,
        bytes.sublist(
          offset,
          offset + 32768 > bytes.length ? bytes.length : offset + 32768,
        ),
      );
    }
  }

  @override
  Future<void> closeInput() async {
    if (_inputClosed || _ended) return;
    _inputClosed = true;
    await _write(3, const []);
  }

  @override
  Future<void> terminate() async {
    if (!_ended) _process.kill();
    await _process.exitCode;
  }
}
