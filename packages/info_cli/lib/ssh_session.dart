import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'credential_output_filter.dart';
import 'ssh_session_transport.dart';

/// Private identity assembled by the host. A public session ID grants nothing.
class SshSessionBinding {
  const SshSessionBinding(this.library, this.device, this.controller);
  final String library, device, controller;
  bool matches(SshSessionBinding other) =>
      library == other.library &&
      device == other.device &&
      controller == other.controller;
}

typedef SshAuthorizationCheck = Future<void> Function(String action);

/// A resident, single-Shell session. All transport writes are serialized, every
/// mutation is authorized immediately before writing, and no write is retried.
class SshSession {
  SshSession({
    required this.id,
    required this.binding,
    required this.transport,
    required this.authorize,
    Iterable<List<int>> secrets = const [],
    this.outputLimit = 1024 * 1024,
    this.responseTimeout = const Duration(seconds: 10),
  }) {
    for (final secret in secrets) {
      registerSecret(secret);
    }
    transport.output.listen(_receive, onError: (_) => _lost(), onDone: _lost);
    transport.diagnostics.listen((bytes) {
      if (!_transportEnded) _append(_diagnosticFilter.add(bytes));
    }, onError: (_) {});
    unawaited(transport.exitCode.then((_) => _lost(), onError: (_) => _lost()));
  }
  final String id;
  final SshSessionBinding binding;
  final SshTransportProcess transport;
  final SshAuthorizationCheck authorize;
  final int outputLimit;
  final Duration responseTimeout;
  final _ready = Completer<void>();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _operations =
      <String, ({String digest, Map<String, dynamic> result})>{};
  final _runs = <String, _Run>{};
  final _secretDigests = <String>{};
  final _chunks = <({int cursor, String text, int size, String? runId})>[];
  final _terminalBytes = <int>[];
  List<int> _frame = [];
  final CredentialOutputFilter _filter = CredentialOutputFilter(const []);
  final CredentialOutputFilter _diagnosticFilter = CredentialOutputFilter(const []);
  Future<void> _writing = Future.value();
  String state = 'opening';
  String? closeReason;
  _Run? _current;
  Map<String, dynamic> capabilities = {};
  int _counter = 0, _cursor = 0, _size = 0;
  bool _transportEnded = false;
  Future<void> get ready => _ready.future;
  void requireController(SshSessionBinding caller) {
    if (!binding.matches(caller)) {
      throw const SshTransportFailure('session_mismatch');
    }
  }

  void registerSecret(List<int> secret) {
    if (secret.isEmpty ||
        !_secretDigests.add(sha256.convert(secret).toString())) {
      return;
    }
    _filter.addSecret(secret);
    _diagnosticFilter.addSecret(secret);
  }

  void _append(List<int> bytes, {String? runId}) {
    if (bytes.isEmpty) return;
    // Hold incomplete UTF-8 sequences between events, preserving split scalars.
    _terminalBytes.addAll(bytes);
    var safe = _terminalBytes.length;
    var continuation = 0;
    for (var i = _terminalBytes.length - 1; i >= 0 && continuation < 3; i--) {
      final byte = _terminalBytes[i];
      if (byte & 0xc0 == 0x80) {
        continuation++;
        continue;
      }
      final width = byte & 0xf8 == 0xf0
          ? 4
          : byte & 0xf0 == 0xe0
          ? 3
          : byte & 0xe0 == 0xc0
          ? 2
          : 1;
      if (width > continuation + 1) safe = i;
      break;
    }
    if (safe == 0) return;
    final text = utf8.decode(
      _terminalBytes.sublist(0, safe),
      allowMalformed: true,
    );
    _terminalBytes.removeRange(0, safe);
    final size = utf8.encode(text).length;
    _chunks.add((
      cursor: ++_cursor,
      text: text,
      size: size,
      runId: runId ?? _current?.id,
    ));
    _size += size;
    while ((_size > outputLimit || _chunks.length > 4096) &&
        _chunks.isNotEmpty) {
      _size -= _chunks.removeAt(0).size;
    }
  }

  void _receive(List<int> bytes) {
    if (_transportEnded) return;
    try {
      for (final byte in bytes) {
        if (byte != 10) {
          if (_frame.length >= 262144) throw const FormatException();
          _frame.add(byte);
          continue;
        }
        final value = jsonDecode(utf8.decode(_frame)) as Map<String, dynamic>;
        _frame = [];
        _event(value);
      }
    } on Object {
      _lost();
      unawaited(transport.terminate());
    }
  }

  void _event(Map<String, dynamic> value) {
    switch (value['type']) {
      case 'ready':
        if (state != 'opening' || value['protocol'] != 1) {
          throw const FormatException();
        }
        capabilities = Map<String, dynamic>.from(value['capabilities'] as Map);
        state = 'ready';
        if (!_ready.isCompleted) _ready.complete();
      case 'reply':
        final response = Map<String, dynamic>.from(value)
          ..remove('type')
          ..remove('id');
        _pending.remove(value['id'])?.complete(response);
      case 'output':
        _append(
          _filter.add(base64Decode(value['data'] as String)),
          runId: value['runId'] as String?,
        );
      case 'credential':
        if (value['runId'] == _current?.id) {
          _current!.receiver = Map<String, dynamic>.from(value)..remove('type');
        }
      case 'exited':
        final run = _runs[value['runId']];
        if (run == null || run != _current) throw const FormatException();
        run.state = 'exited';
        run.exitCode = value['exitCode'] as int;
        run.receiver = null;
        _current = null;
        if (state == 'busy') {
          state = value['reusable'] == false ? 'draining' : 'ready';
        }
      case 'unusable':
        state = 'draining';
        closeReason = value['reason'] as String?;
      case 'unsupported':
        closeReason = value['capability'] as String?;
        _lost();
      case 'closed':
        state = 'closed';
        _unknownRun();
      default:
        throw const FormatException();
    }
  }

  void _unknownRun() {
    if (_current case final run?) {
      run.state = 'unknown';
      run.receiver = null;
      _current = null;
    }
  }

  void _lost() {
    if (_transportEnded) return;
    _transportEnded = true;
    if (state != 'closed' && state != 'draining') state = 'lost';
    if (state == 'draining' && _current == null) state = 'closed';
    _unknownRun();
    _append(_filter.finish());
    _append(_diagnosticFilter.finish());
    if (!_ready.isCompleted) {
      _ready.completeError(
        const SshTransportFailure('remote_capability_unavailable'),
      );
    }
    for (final pending in _pending.values) {
      pending.complete({'status': 'operation_unknown'});
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _send(
    Map<String, Object?> value, {
    Future<void> Function()? authorizeDelivery,
  }) async {
    if (_transportEnded) return {'status': 'operation_unknown'};
    final key = 'c${++_counter}';
    final response = Completer<Map<String, dynamic>>();
    _pending[key] = response;
    var attempted = false;
    Future<void> submit() async {
      final op = value['op'];
      if (op == 'run' || op == 'input' || op == 'credential') {
        await authorize(op as String);
        if (authorizeDelivery != null) await authorizeDelivery();
        final stale =
            state != 'busy' ||
            _current?.id != value['runId'] ||
            op == 'credential' &&
                _current?.receiver?['actionId'] != value['actionId'];
        if (stale) {
          _pending.remove(key);
          response.complete({
            'status': op == 'credential' ? 'stale_receiver' : 'stale_run',
          });
          return;
        }
      }
      attempted = true;
      await transport.send(
        utf8.encode('${jsonEncode({...value, 'id': key})}\n'),
      );
    }

    final cleanup = value['op'] == 'interrupt' || value['op'] == 'close';
    final write = cleanup ? submit() : _writing.then((_) => submit());
    if (!cleanup) _writing = write.then((_) {}, onError: (_) {});
    try {
      await write;
    } on Object {
      if (attempted) {
        _lost();
      } else {
        _pending.remove(key);
        rethrow;
      }
    }
    return response.future.timeout(
      responseTimeout,
      onTimeout: () {
        _pending.remove(key);
        return {'status': 'operation_unknown'};
      },
    );
  }

  String _digest(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  Map<String, dynamic>? _previous(String operation, Object? value) {
    final previous = _operations[operation];
    if (previous == null) {
      if (_operations.length >= 4096) {
        throw const SshTransportFailure('operation_limit');
      }
      _operations[operation] = (
        digest: _digest(value),
        result: {'status': 'operation_unknown'},
      );
      return null;
    }
    if (previous.digest != _digest(value)) {
      throw const SshTransportFailure('operation_conflict');
    }
    return Map<String, dynamic>.from(previous.result);
  }

  Map<String, dynamic> _remember(String operation, Map<String, dynamic> value) {
    _operations[operation] = (
      digest: _operations[operation]!.digest,
      result: value,
    );
    return value;
  }

  Map<String, dynamic> status({String? runId}) => {
    'status': 'ok',
    'sessionId': id,
    'sessionState': state,
    'reason': ?closeReason,
    'capabilities': capabilities,
    if (runId != null && _runs[runId] != null) 'run': _runs[runId]!.toJson(),
    if (runId == null && _current != null) 'run': _current!.toJson(),
  };
  Map<String, dynamic> output({int cursor = 0, String? runId}) => {
    ...status(runId: runId),
    'cursor': _cursor,
    'gap': cursor < (_chunks.firstOrNull?.cursor ?? (_cursor + 1)) - 1,
    'mergedOutput': true,
    'output': _chunks
        .where((e) => e.cursor > cursor && (runId == null || e.runId == runId))
        .map((e) => {'cursor': e.cursor, 'runId': e.runId, 'text': e.text})
        .toList(),
  };
  Future<Map<String, dynamic>> run(String operation, String command) async {
    final old = _previous(operation, ['run', command]);
    if (old != null) return old;
    if (state != 'ready') {
      return _remember(operation, {
        'status': state == 'busy' ? 'busy' : 'session_closed',
      });
    }
    if (utf8.encode(command).length > 65536 || command.contains('\x00')) {
      return _remember(operation, {'status': 'invalid_command'});
    }
    final run = _Run(operation);
    _current = run;
    _runs[run.id] = run;
    state = 'busy';
    try {
      await authorize('run');
      if (_current != run || state != 'busy') {
        return _remember(operation, {'status': 'operation_unknown'});
      }
      final result = await _send({
        'op': 'run',
        'runId': run.id,
        'command': command,
      });
      if (result['status'] == 'accepted' && run.state == 'accepted') {
        run.state = 'running';
      }
      if (result['status'] == 'operation_unknown' && _current == run) {
        run.state = 'unknown';
      } else if (result['status'] != 'accepted' && _current == run) {
        run.state = 'failed';
        _current = null;
        if (state == 'busy') state = 'ready';
      }
      return _remember(operation, {
        ...result,
        'sessionId': id,
        'runId': run.id,
      });
    } on Object {
      run.state = 'failed';
      if (_current == run) _current = null;
      if (state == 'busy') state = 'ready';
      rethrow;
    }
  }

  Future<Map<String, dynamic>> input(
    String runId,
    String inputId,
    List<int> bytes,
  ) async {
    final old = _previous(inputId, ['input', runId, base64Encode(bytes)]);
    if (old != null) return old;
    await authorize('input');
    if (state != 'busy' || _current?.id != runId) {
      return _remember(inputId, {'status': 'stale_run'});
    }
    return _remember(
      inputId,
      await _send({
        'op': 'input',
        'runId': runId,
        'inputId': inputId,
        'data': base64Encode(bytes),
      }),
    );
  }

  Future<Map<String, dynamic>> credential(
    String runId,
    String operation,
    String actionId,
    Future<List<int>> Function() claim, {
    required Future<void> Function() authorizeDelivery,
  }) async {
    final old = _previous(operation, ['credential', runId, actionId]);
    if (old != null) return old;
    await authorize('credential');
    if (state != 'busy' ||
        _current?.id != runId ||
        _current?.receiver?['actionId'] != actionId) {
      return _remember(operation, {'status': 'stale_receiver'});
    }
    final secret = await claim();
    // Approval/claim can outlive the program or receiver. Check both again.
    await authorize('credential');
    if (state != 'busy' ||
        _current?.id != runId ||
        _current?.receiver?['actionId'] != actionId) {
      return _remember(operation, {'status': 'stale_receiver'});
    }
    registerSecret(secret);
    final result = await _send({
      'op': 'credential',
      'runId': runId,
      'actionId': actionId,
      'data': base64Encode(secret),
    }, authorizeDelivery: authorizeDelivery);
    if (result['status'] == 'delivered') _current?.receiver = null;
    return _remember(operation, result);
  }

  Future<Map<String, dynamic>> interrupt(String runId) async {
    if (_current?.id != runId) return {'status': 'stale_run'};
    return _send({'op': 'interrupt', 'runId': runId});
  }

  Future<Map<String, dynamic>> close({bool force = false}) async {
    if (_transportEnded) return status();
    state = 'draining';
    if (force) {
      _unknownRun();
      await transport.terminate();
      state = 'closed';
      return {'status': 'closed', 'sessionState': state};
    }
    final result = await _send({'op': 'close', 'force': false});
    return {...result, 'sessionState': state};
  }

  Future<void> authorizationLost() async {
    if (!{'ready', 'busy'}.contains(state)) return;
    await close();
  }
}

class _Run {
  _Run(this.id);
  final String id;
  String state = 'accepted';
  int? exitCode;
  Map<String, dynamic>? receiver;
  Map<String, Object?> toJson() => {
    'runId': id,
    'state': state,
    'exitCode': ?exitCode,
    if (receiver != null) 'credentialReceiver': receiver,
  };
}
