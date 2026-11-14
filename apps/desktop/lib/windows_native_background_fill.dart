import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:info_core/info_core.dart';

/// App-owned Windows transport. The identity must come from the trusted bundle,
/// never an Agent request or environment/config lookup. One instance belongs
/// to one authenticated AppHost; its owner disposes it at host shutdown.
/// Individual CLI connections do not own it. No target is reconstructed after
/// helper loss.
class WindowsNativeFillDriver implements NativeFillDriver {
  WindowsNativeFillDriver({
    required this.helper,
    this.timeout = const Duration(seconds: 6),
  });

  final FocusedFillApplication helper;
  final Duration timeout;
  _NativeBroker? _broker;
  Future<_NativeBroker>? _starting;
  Future<void>? _disposing;
  bool _disposed = false;

  /// Startup-only private handshake, before advertising the platform driver.
  /// It discovers no targets and never resurrects a lost helper incarnation.
  Future<void> initialize() async {
    if (_broker != null && !_broker!.alive) {
      throw const CredentialUseFailure('session_unavailable');
    }
    await _connection(discover: true);
  }

  Future<_NativeBroker> _connection({bool discover = false}) async {
    if (_disposed) {
      throw const CredentialUseFailure('session_unavailable');
    }
    final current = _broker;
    if (current != null && current.alive) return current;
    if (!discover) {
      throw const CredentialUseFailure('session_unavailable');
    }
    // An explicit new discovery may start a new incarnation. prepare/setValue
    // never do; old snapshots and their helper-held objects remain invalid.
    final pending = _starting ??= _start();
    try {
      final ready = await pending;
      if (_disposed) {
        await ready.dispose();
        throw const CredentialUseFailure('session_unavailable');
      }
      return _broker = ready;
    } finally {
      if (identical(_starting, pending)) _starting = null;
    }
  }

  Future<_NativeBroker> _start() async {
    if (!Platform.isWindows) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    Process? process;
    _NativeBroker? broker;
    try {
      await inspectFocusedFillApplication(helper);
      process = await Process.start(
        helper.executable,
        const ['--native-background-v1'],
        workingDirectory: File(helper.executable).parent.path,
        environment: {
          for (final key in ['SystemRoot', 'WINDIR'])
            if (Platform.environment[key] != null)
              key: Platform.environment[key]!,
        },
        includeParentEnvironment: false,
        runInShell: false,
      );
      broker = _NativeBroker(process, timeout);
      await inspectFocusedFillApplication(helper);
      final init = Uint8List(38);
      init[0] = 1;
      ByteData.sublistView(init).setUint32(2, pid, Endian.little);
      for (var i = 0; i < 32; i++) {
        init[6 + i] = int.parse(
          helper.sha256.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }
      final hello = await broker.exchangeBytes(init);
      if (!_shape(hello, {'format', 'state', 'helperInstanceId'}) ||
          hello['state'] != 'ready' ||
          !_reference(hello['helperInstanceId'])) {
        throw const CredentialUseFailure('session_unavailable');
      }
      broker.instance = hello['helperInstanceId'] as String;
      return broker;
    } on Object {
      if (broker != null) {
        await broker.dispose();
      } else {
        process?.kill();
      }
      throw const CredentialUseFailure('session_unavailable');
    }
  }

  @override
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  }) async {
    _scope(scope);
    if (!RegExp(r'^[A-Za-z]:[/\\]').hasMatch(appId) ||
        appId.length > 4096 ||
        appId.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const CredentialUseFailure('unsupported_target');
    }
    if (windowId != null && !_reference(windowId)) {
      throw const CredentialUseFailure('target_unavailable');
    }
    final broker = await _connection(discover: true);
    final reply = await broker.exchange({
      'format': 1,
      'command': 'discover',
      'scope': scope,
      'appId': appId,
      'windowId': ?windowId,
    });
    _throwRefusal(reply);
    if (!_shape(reply, {'format', 'state', 'targets'}) ||
        reply['state'] != 'ready' ||
        reply['targets'] is! List ||
        (reply['targets'] as List).length > 64) {
      await broker.dispose();
      throw const CredentialUseFailure('session_unavailable');
    }
    try {
      final targets = [
        for (final raw in reply['targets'] as List)
          NativeFillTarget.fromJson(_map(raw)),
      ];
      final ids = <String>{};
      for (final target in targets) {
        if (target.platform != 'windows' ||
            target.appId != appId ||
            target.helperInstanceId != broker.instance ||
            windowId != null && target.windowId != windowId ||
            !ids.add(target.targetId)) {
          throw const CredentialUseFailure('destination_changed');
        }
      }
      return targets;
    } on Object {
      await broker.dispose();
      throw const CredentialUseFailure('session_unavailable');
    }
  }

  @override
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  }) async {
    _scope(scope);
    if (!_reference(targetId) ||
        expected != null && expected.targetId != targetId) {
      throw const CredentialUseFailure('target_unavailable');
    }
    final broker = await _connection();
    final prepared = await _prepare(broker, scope, targetId, expected);
    return _WindowsPrepared(broker, scope, prepared.$1, prepared.$2);
  }

  @override
  Future<void> release({
    required String scope,
    required String targetId,
  }) async {
    _scope(scope);
    if (!_reference(targetId)) {
      throw const CredentialUseFailure('target_unavailable');
    }
    final broker = _broker;
    // A dead incarnation already forgot every target. Do not start another
    // helper to release an old reference.
    if (broker == null || !broker.alive) return;
    final reply = await broker.exchange({
      'format': 1,
      'command': 'release',
      'scope': scope,
      'targetId': targetId,
    });
    _throwRefusal(reply);
    if (!_shape(reply, {'format', 'state'}) || reply['state'] != 'released') {
      await broker.dispose();
      throw const CredentialUseFailure('session_unavailable');
    }
  }

  /// Idempotently destroys this private connection and all helper references.
  @override
  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= _dispose();
  }

  Future<void> _dispose() async {
    await _broker?.dispose();
    final pending = _starting;
    if (pending != null) {
      try {
        await (await pending).dispose();
      } on Object {
        // Startup did not yield a usable connection.
      }
    }
  }
}

Future<(NativeFillTarget, String)> _prepare(
  _NativeBroker broker,
  String scope,
  String targetId,
  NativeFillTarget? expected,
) async {
  if (expected != null &&
      (expected.platform != 'windows' ||
          expected.helperInstanceId != broker.instance)) {
    throw const CredentialUseFailure('target_unavailable');
  }
  final reply = await broker.exchange({
    'format': 1,
    'command': 'prepare',
    'scope': scope,
    'targetId': targetId,
    if (expected != null) 'expected': expected.toJson(),
  });
  _throwRefusal(reply);
  try {
    if (!_shape(reply, {'format', 'state', 'target', 'leaseId'}) ||
        reply['state'] != 'prepared' ||
        !_reference(reply['leaseId'])) {
      throw const CredentialUseFailure('session_unavailable');
    }
    final target = NativeFillTarget.fromJson(_map(reply['target']));
    if (target.platform != 'windows' ||
        target.targetId != targetId ||
        target.helperInstanceId != broker.instance ||
        expected != null && !target.matches(expected)) {
      throw const CredentialUseFailure('destination_changed');
    }
    return (target, reply['leaseId'] as String);
  } on Object {
    await broker.dispose();
    throw const CredentialUseFailure('destination_changed');
  }
}

class _WindowsPrepared implements PreparedNativeFill {
  _WindowsPrepared(this.broker, this.scope, this.target, this._leaseId);
  final _NativeBroker broker;
  final String scope;
  @override
  final NativeFillTarget target;
  String? _leaseId;
  bool _closed = false;
  Future<void>? _closing;
  Future<NativeFillResult>? _result;

  @override
  Future<NativeFillResult> setValue(
    List<int> utf8Bytes, {
    required Future<void> Function() beforeDispatch,
  }) => _result ??= _setValue(utf8Bytes, beforeDispatch);

  Future<NativeFillResult> _setValue(
    List<int> input,
    Future<void> Function() beforeDispatch,
  ) async {
    if (_closed || !broker.alive) {
      return const NativeFillResult(
        NativeFillState.refused,
        'target_unavailable',
      );
    }
    if (!_validSecret(input)) {
      return const NativeFillResult(
        NativeFillState.refused,
        'unsupported_secret',
      );
    }
    final bytes = Uint8List.fromList(input);
    var dispatched = false;
    try {
      // Refresh only the execution reservation, retaining the exact same
      // target object and snapshot. This supplies the last read-only check
      // before the grant callback without adding a new public wire command.
      final old = _leaseId;
      _leaseId = null;
      if (old != null) await _closeLease(broker, scope, old);
      final checked = await _prepare(broker, scope, target.targetId, target);
      _leaseId = checked.$2;
      if (_closed) {
        return const NativeFillResult(
          NativeFillState.refused,
          'target_unavailable',
        );
      }
      await beforeDispatch();
      if (_closed || !broker.alive) {
        return const NativeFillResult(
          NativeFillState.refused,
          'target_unavailable',
        );
      }
      dispatched = true;
      final reply = await broker.exchange({
        'format': 1,
        'command': 'setValue',
        'scope': scope,
        'leaseId': _leaseId,
        'bytes': bytes,
      });
      if (reply['format'] != 1) throw const FormatException();
      return NativeFillResult.fromJson({
        for (final entry in reply.entries)
          if (entry.key != 'format') entry.key: entry.value,
      });
    } on CredentialUseFailure catch (failure) {
      if (!dispatched) {
        return NativeFillResult(
          NativeFillState.refused,
          nativeFillErrorCodes.contains(failure.code)
              ? failure.code
              : 'scope_not_approved',
        );
      }
      return const NativeFillResult(NativeFillState.unknown, 'fill_unknown');
    } on Object {
      return NativeFillResult(
        dispatched ? NativeFillState.unknown : NativeFillState.refused,
        dispatched ? 'fill_unknown' : 'scope_not_approved',
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      // close does not release the retained target. A lost reply makes the
      // broker unusable; cleanup never reconnects or repeats setValue.
      _closed = true;
      final lease = _leaseId;
      _leaseId = null;
      if (lease != null) await _closeLease(broker, scope, lease);
      await _closing;
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      final lease = _leaseId;
      _leaseId = null;
      if (lease != null) await _closeLease(broker, scope, lease);
    }();
  }
}

Future<void> _closeLease(
  _NativeBroker broker,
  String scope,
  String lease,
) async {
  if (!broker.alive) return;
  try {
    final reply = await broker.exchange({
      'format': 1,
      'command': 'close',
      'scope': scope,
      'leaseId': lease,
    });
    if (!_shape(reply, {'format', 'state'}) || reply['state'] != 'closed') {
      await broker.dispose();
    }
  } on Object {
    await broker.dispose();
  }
}

bool _validSecret(List<int> bytes) {
  if (bytes.isEmpty ||
      bytes.length > 16384 ||
      bytes.any((b) => b < 0 || b > 255)) {
    return false;
  }
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    return text.isNotEmpty &&
        text.length <= 4096 &&
        !text.codeUnits.any((c) => c < 32 || c == 127);
  } on Object {
    return false;
  }
}

void _scope(String scope) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(scope)) {
    throw const CredentialUseFailure('scope_not_approved');
  }
}

bool _reference(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{22,128}$').hasMatch(value);

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const CredentialUseFailure('session_unavailable');
  }
  return value;
}

bool _shape(Map<String, dynamic> value, Set<String> keys) =>
    value['format'] == 1 &&
    value.length == keys.length &&
    value.keys.every(keys.contains);

void _throwRefusal(Map<String, dynamic> reply) {
  if (reply['state'] != 'refused') return;
  if (!_shape(reply, {'format', 'state', 'errorCode'}) ||
      !nativeFillErrorCodes.contains(reply['errorCode'])) {
    throw const CredentialUseFailure('session_unavailable');
  }
  throw CredentialUseFailure(reply['errorCode'] as String);
}

class _NativeBroker {
  _NativeBroker(this.process, this.timeout) {
    _stdout = process.stdout.listen(
      _receive,
      onError: (Object _) => _abort(),
      onDone: _abort,
    );
    // Helper diagnostics never become model text or exception messages.
    _stderr = process.stderr.listen((_) {}, onError: (Object _) {});
    unawaited(process.exitCode.then((_) => _abort()));
  }

  static const _maxFrame = 2 * 1024 * 1024;
  final Process process;
  final Duration timeout;
  late final StreamSubscription<List<int>> _stdout, _stderr;
  final List<int> _incoming = [];
  Future<void> _tail = Future.value();
  Completer<Map<String, dynamic>>? _pending;
  String? instance;
  bool alive = true;
  Future<void>? _disposing;

  void _receive(List<int> chunk) {
    if (!alive) return;
    if (_incoming.length + chunk.length > _maxFrame + 4) {
      _abort();
      return;
    }
    _incoming.addAll(chunk);
    if (_incoming.length < 4) return;
    final size =
        _incoming[0] |
        _incoming[1] << 8 |
        _incoming[2] << 16 |
        _incoming[3] << 24;
    if (size < 2 || size > _maxFrame) {
      _abort();
      return;
    }
    if (_incoming.length < size + 4) return;
    final pending = _pending;
    if (pending == null || _incoming.length != size + 4) {
      _abort();
      return;
    }
    try {
      final json = _map(jsonDecode(utf8.decode(_incoming.sublist(4))));
      _incoming.clear();
      _pending = null;
      pending.complete(json);
    } on Object {
      _abort();
    }
  }

  Future<Map<String, dynamic>> exchange(Map<String, Object?> message) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    return exchangeBytes(bytes);
  }

  Future<Map<String, dynamic>> exchangeBytes(Uint8List bytes) async {
    final previous = _tail, done = Completer<void>();
    _tail = done.future;
    try {
      await previous;
      if (!alive || bytes.length > _maxFrame) {
        throw const CredentialUseFailure('session_unavailable');
      }
      final pending = Completer<Map<String, dynamic>>();
      _pending = pending;
      // Attach an immediate error observer even when a pipe flush fails before
      // the response await. Neither stream errors nor payloads are exposed.
      unawaited(
        pending.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      final header = Uint8List(4);
      ByteData.sublistView(header).setUint32(0, bytes.length, Endian.little);
      process.stdin.add(header);
      process.stdin.add(bytes);
      await process.stdin.flush().timeout(timeout);
      bytes.fillRange(0, bytes.length, 0);
      return await pending.future.timeout(timeout);
    } on Object {
      _abort();
      throw const CredentialUseFailure('session_unavailable');
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      done.complete();
    }
  }

  void _abort() {
    if (!alive) return;
    alive = false;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const CredentialUseFailure('session_unavailable'));
    }
    _incoming.clear();
    process.kill();
  }

  Future<void> dispose() => _disposing ??= () async {
    _abort();
    try {
      await process.stdin.close().timeout(const Duration(seconds: 1));
    } on Object {
      // Already closed or lost.
    }
    await _stdout.cancel();
    await _stderr.cancel();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      process.kill();
    }
  }();
}
