import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';

/// The owner supplies the bundled helper identity. Agent requests cannot select
/// a helper, environment, PID, HWND or secret. Each operation has its own child;
/// stdin carries bounded binary frames, stdout only validated metadata.
class WindowsFocusedFillDriver implements FocusedFillDiscoveryDriver {
  WindowsFocusedFillDriver({
    required this.helper,
    this.timeout = const Duration(seconds: 4),
  });
  final FocusedFillApplication helper;
  final Duration timeout;
  Future<_Broker> _start() async {
    if (!Platform.isWindows) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    await inspectFocusedFillApplication(helper);
    final process = await Process.start(
      helper.executable,
      const ['--broker-v1'],
      workingDirectory: File(helper.executable).parent.path,
      environment: {
        for (final name in ['SystemRoot', 'WINDIR'])
          if (Platform.environment[name] != null)
            name: Platform.environment[name]!,
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    final broker = _Broker(process, timeout);
    try {
      await inspectFocusedFillApplication(helper);
      return broker;
    } on Object {
      await broker.close();
      throw const CredentialUseFailure('application_changed');
    }
  }

  Uint8List _initialize(int opcode, [FocusedFillApplication? application]) {
    final units = application?.executable.codeUnits ?? const <int>[];
    final body = Uint8List(application == null ? 38 : 72 + units.length * 2);
    final view = ByteData.sublistView(body);
    body[0] = 1;
    body[1] = opcode;
    view.setUint32(2, pid, Endian.little);
    void digest(int offset, String hash) {
      for (var i = 0; i < 32; i++) {
        body[offset + i] = int.parse(
          hash.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }
    }

    digest(6, helper.sha256);
    if (application != null) {
      digest(38, application.sha256);
      view.setUint16(70, units.length, Endian.little);
      for (var i = 0; i < units.length; i++) {
        view.setUint16(72 + i * 2, units[i], Endian.little);
      }
    }
    return body;
  }

  @override
  Future<FocusedFillTarget> inspectTarget() async {
    final broker = await _start();
    try {
      final response = await broker.exchange(_initialize(0));
      if (response.state == 'ready') {
        return FocusedFillTarget.ready(response.application!);
      }
      if (response.state == 'refused') {
        return FocusedFillTarget.refused(response.error!);
      }
      throw const CredentialUseFailure('unsupported_target');
    } finally {
      await broker.close();
    }
  }

  @override
  Future<PreparedFocusedFill> prepare(
    FocusedFillApplication application,
  ) async {
    final broker = await _start();
    try {
      final response = await broker.exchange(_initialize(1, application));
      if (response.state == 'refused') {
        throw CredentialUseFailure(response.error!);
      }
      if (response.state != 'prepared' ||
          !application.matches(response.application!)) {
        throw const CredentialUseFailure('application_changed');
      }
      return _PreparedBroker(broker, application);
    } on Object {
      await broker.close();
      rethrow;
    }
  }
}

class _Response {
  _Response(this.state, this.error, this.application);
  final String state;
  final String? error;
  final FocusedFillApplication? application;
  factory _Response.parse(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic> ||
        json['format'] != 1 ||
        json.keys.any(
          (k) => !{'format', 'state', 'errorCode', 'application'}.contains(k),
        )) {
      throw const CredentialUseFailure('fill_unknown');
    }
    final state = json['state'];
    final error = json['errorCode'];
    if ({'ready', 'prepared'}.contains(state) &&
        json.length == 3 &&
        json['application'] is Map<String, dynamic> &&
        !json.containsKey('errorCode')) {
      return _Response(
        state as String,
        null,
        FocusedFillApplication.fromJson(
          json['application'] as Map<String, dynamic>,
        ),
      );
    }
    if (state == 'sent' && json.length == 2) {
      return _Response('sent', null, null);
    }
    if ({'refused', 'partial', 'unknown'}.contains(state) &&
        json.length == 3 &&
        focusedFillErrorCodes.contains(error) &&
        !json.containsKey('application')) {
      return _Response(state as String, error as String, null);
    }
    throw const CredentialUseFailure('fill_unknown');
  }
}

class _Broker {
  _Broker(this.process, this.timeout) {
    _output = process.stdout.listen(
      _receive,
      onError: (Object _) => _fail(),
      onDone: _fail,
    );
    _errors = process.stderr.listen(
      (_) => _protocolFailure(),
      onError: (Object _) => _protocolFailure(),
    );
    // Process exit can precede delivery of its final pipe bytes. EOF, not an
    // exit callback racing stdout, decides whether a reply was lost.
    unawaited(
      process.exitCode.then((_) {
        _exited = true;
      }),
    );
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
  final Process process;
  final Duration timeout;
  late final StreamSubscription<List<int>> _output, _errors;
  Completer<_Response>? _pending;
  final _line = <int>[];
  bool _closed = false, _exited = false;
  bool _failed = false;
  Future<void>? _closing;
  void _fail() {
    final waiting = _pending;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(const CredentialUseFailure('fill_unknown'));
    }
  }

  void _protocolFailure() {
    _failed = true;
    _fail();
    process.kill();
  }

  void _receive(List<int> data) {
    try {
      for (final byte in data) {
        if (_line.length >= 32768) throw const FormatException();
        if (byte == 10) {
          final pending = _pending;
          if (pending == null || pending.isCompleted) {
            throw const FormatException();
          }
          final response = _Response.parse(_line);
          _line.clear();
          pending.complete(response);
        } else {
          _line.add(byte);
        }
      }
      if (_pending?.isCompleted == true && _line.isNotEmpty) {
        throw const FormatException();
      }
    } on Object {
      _protocolFailure();
    }
  }

  Future<_Response> exchange(Uint8List body) async {
    if (_closed || _exited || _failed || _pending != null) {
      throw const CredentialUseFailure('service_unavailable');
    }
    final reply = Completer<_Response>();
    _pending = reply;
    unawaited(
      reply.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final header = ByteData(4)..setUint32(0, body.length, Endian.little);
    try {
      // Do not JSON/base64-encode input, retain frames, or send them to logs.
      process.stdin.add(header.buffer.asUint8List());
      process.stdin.add(body);
      await process.stdin.flush().timeout(timeout);
      final response = await reply.future.timeout(timeout);
      if (_failed) throw const CredentialUseFailure('fill_unknown');
      return response;
    } on Object {
      await close();
      throw const CredentialUseFailure('fill_unknown');
    } finally {
      _pending = null;
      body.fillRange(0, body.length, 0);
    }
  }

  Future<void> close() => _closing ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    _fail();
    if (!_exited) process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      /* Not a successful input result. */
    }
    await _output.cancel();
    await _errors.cancel();
    try {
      await process.stdin.close().timeout(const Duration(seconds: 2));
    } on Object {
      /* No raw pipe error. */
    }
    _line.clear();
  }
}

class _PreparedBroker implements PreparedFocusedFill {
  _PreparedBroker(this._broker, this.application);
  final _Broker _broker;
  @override
  final FocusedFillApplication application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    if (units.isEmpty ||
        units.length > 16 ||
        units.any((c) => c < 32 || c == 127 || c > 65535)) {
      throw const CredentialUseFailure('unsupported_secret');
    }
    final body = Uint8List(4 + units.length * 2);
    final view = ByteData.sublistView(body);
    body[0] = 1;
    body[1] = 2;
    view.setUint16(2, units.length, Endian.little);
    for (var i = 0; i < units.length; i++) {
      view.setUint16(4 + i * 2, units[i], Endian.little);
    }
    final response = await _broker.exchange(body);
    final state = FocusedFillState.values
        .where((s) => s.name == response.state)
        .firstOrNull;
    if (state == null || state == FocusedFillState.checking) {
      throw const CredentialUseFailure('fill_unknown');
    }
    return FocusedFillBatchResult(state, response.error);
  }

  @override
  Future<void> close() => _broker.close();
}
