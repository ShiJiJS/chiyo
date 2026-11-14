import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';

/// Owner-side private bridge. Scope isolates references; only the authenticated
/// AppHost and its beforeDispatch callback authorize credential delivery.
class MacOSNativeBackgroundFillDriver implements NativeFillDriver {
  MacOSNativeBackgroundFillDriver({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 6),
  }) : _channel = _OwnedNativeChannel(
         channel ??
             const MethodChannel('agent_info_manage/native_background_fill'),
       );

  final _OwnedNativeChannel _channel;
  final Duration timeout;
  bool _disposed = false;
  Future<void>? _disposing;

  /// Owned AppHost lifecycle, independent of every operation's close().
  @override
  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= _dispose(_channel, timeout);
  }

  void _own(String scope) {
    if (_disposed) throw const CredentialUseFailure('session_unavailable');
    _scope(scope);
  }

  @override
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  }) async {
    _own(scope);
    if (appId.isEmpty ||
        appId.length > 4096 ||
        windowId != null && !_id(windowId)) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final reply = await _call(_channel, 'discover', {
      'scope': scope,
      'appId': appId,
      'windowId': ?windowId,
    }, timeout);
    _refusal(reply);
    if (!_shape(reply, {'format', 'state', 'targets'}) ||
        reply['state'] != 'ready' ||
        reply['targets'] is! List) {
      throw const CredentialUseFailure('session_unavailable');
    }
    final raw = reply['targets'] as List;
    if (raw.length > 64) {
      throw const CredentialUseFailure('session_unavailable');
    }
    final targets = raw.map(_target).toList(growable: false);
    if (targets.map((t) => t.targetId).toSet().length != targets.length ||
        targets.any(
          (t) => t.appId != appId || windowId != null && t.windowId != windowId,
        )) {
      throw const CredentialUseFailure('destination_changed');
    }
    return targets;
  }

  @override
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  }) async {
    _own(scope);
    if (!_id(targetId)) throw const CredentialUseFailure('invalid_reference');
    final prepared = await _prepare(
      _channel,
      scope,
      targetId,
      expected,
      timeout,
    );
    return _MacNativePrepared(
      _channel,
      scope,
      prepared.$1,
      prepared.$2,
      timeout,
      () => _disposed,
    );
  }

  @override
  Future<void> release({
    required String scope,
    required String targetId,
  }) async {
    _own(scope);
    if (!_id(targetId)) throw const CredentialUseFailure('invalid_reference');
    final reply = await _call(_channel, 'release', {
      'scope': scope,
      'targetId': targetId,
    }, timeout);
    _refusal(reply);
    if (!_shape(reply, {'format', 'state'}) || reply['state'] != 'released') {
      throw const CredentialUseFailure('session_unavailable');
    }
  }
}

class _MacNativePrepared implements PreparedNativeFill {
  _MacNativePrepared(
    this.channel,
    this.scope,
    this.target,
    this.lease,
    this.timeout,
    this.ownerDisposed,
  );
  final _OwnedNativeChannel channel;
  final String scope;
  @override
  final NativeFillTarget target;
  String lease;
  final Duration timeout;
  final bool Function() ownerDisposed;
  bool closed = false, attempted = false;
  Future<void>? closing;

  @override
  Future<NativeFillResult> setValue(
    List<int> utf8Bytes, {
    required Future<void> Function() beforeDispatch,
  }) async {
    if (closed || ownerDisposed() || attempted) {
      return const NativeFillResult(
        NativeFillState.refused,
        'target_unavailable',
      );
    }
    attempted = true;
    if (!_valid(utf8Bytes)) {
      return const NativeFillResult(
        NativeFillState.refused,
        'unsupported_secret',
      );
    }
    final bytes = Uint8List.fromList(utf8Bytes);
    var dispatched = false;
    try {
      // Renew only the operation ticket for the SAME retained target. This is
      // the final read-only preflight before the owner's approval callback.
      await _close(channel, scope, lease, timeout);
      final renewed = await _prepare(
        channel,
        scope,
        target.targetId,
        target,
        timeout,
      );
      lease = renewed.$2;
      if (closed || ownerDisposed()) {
        await _close(channel, scope, lease, timeout);
        return const NativeFillResult(
          NativeFillState.refused,
          'target_unavailable',
        );
      }
      await beforeDispatch();
      if (closed || ownerDisposed()) {
        return const NativeFillResult(
          NativeFillState.refused,
          'target_unavailable',
        );
      }
      dispatched = true;
      final reply = await _call(channel, 'setValue', {
        'scope': scope,
        'leaseId': lease,
        'bytes': bytes,
      }, timeout);
      if (reply.keys.any(
        (k) => !{'format', 'state', 'errorCode'}.contains(k),
      )) {
        return const NativeFillResult(NativeFillState.unknown, 'fill_unknown');
      }
      return NativeFillResult.fromJson(
        Map<String, dynamic>.from(reply)..remove('format'),
      );
    } on CredentialUseFailure catch (error) {
      if (dispatched) {
        return const NativeFillResult(NativeFillState.unknown, 'fill_unknown');
      }
      return NativeFillResult(
        NativeFillState.refused,
        nativeFillErrorCodes.contains(error.code)
            ? error.code
            : 'session_unavailable',
      );
    } on Object {
      return NativeFillResult(
        dispatched ? NativeFillState.unknown : NativeFillState.refused,
        dispatched ? 'fill_unknown' : 'session_unavailable',
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      await _close(channel, scope, lease, timeout);
    }
  }

  @override
  Future<void> close() {
    closed = true;
    return closing ??= _close(channel, scope, lease, timeout);
  }
}

Future<(NativeFillTarget, String)> _prepare(
  _OwnedNativeChannel channel,
  String scope,
  String id,
  NativeFillTarget? expected,
  Duration timeout,
) async {
  final reply = await _call(channel, 'prepare', {
    'scope': scope,
    'targetId': id,
    if (expected != null) 'expected': expected.toJson(),
  }, timeout);
  _refusal(reply);
  if (!_shape(reply, {'format', 'state', 'target', 'leaseId'}) ||
      reply['state'] != 'prepared' ||
      reply['leaseId'] is! String ||
      !_id(reply['leaseId'] as String)) {
    throw const CredentialUseFailure('session_unavailable');
  }
  final target = _target(reply['target']);
  if (target.targetId != id || expected != null && !expected.matches(target)) {
    await _close(channel, scope, reply['leaseId'] as String, timeout);
    throw const CredentialUseFailure('destination_changed');
  }
  return (target, reply['leaseId'] as String);
}

Future<Map<Object?, Object?>> _call(
  _OwnedNativeChannel channel,
  String command,
  Map<String, Object?> arguments,
  Duration timeout,
) async {
  try {
    final raw = await channel
        .invokeMethod<Object?>(command, {
          'format': 1,
          'command': command,
          ...arguments,
        })
        .timeout(timeout);
    if (raw is! Map || raw['format'] != 1) {
      throw const CredentialUseFailure('session_unavailable');
    }
    return Map<Object?, Object?>.from(raw);
  } on CredentialUseFailure {
    rethrow;
  } on Object {
    throw const CredentialUseFailure('session_unavailable');
  }
}

Future<void> _close(
  _OwnedNativeChannel channel,
  String scope,
  String lease,
  Duration timeout,
) async {
  try {
    await _call(channel, 'close', {'scope': scope, 'leaseId': lease}, timeout);
  } on Object {
    /* terminal best effort */
  }
}

NativeFillTarget _target(Object? raw) {
  if (raw is! Map) throw const CredentialUseFailure('unsupported_target');
  // StandardMessageCodec recursively returns Map<Object?, Object?>. Normalize
  // metadata to JSON types before the strict shared DTO parser inspects it.
  final target = NativeFillTarget.fromJson(
    jsonDecode(jsonEncode(raw)) as Map<String, dynamic>,
  );
  if (target.platform != 'macos' || target.controlKind != 'macos_ax_password') {
    throw const CredentialUseFailure('unsupported_target');
  }
  return target;
}

void _scope(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const CredentialUseFailure('scope_not_approved');
  }
}

bool _id(String value) => RegExp(r'^[A-Za-z0-9_-]{22,128}$').hasMatch(value);
bool _shape(Map<Object?, Object?> value, Set<String> keys) =>
    value.length == keys.length && value.keys.every(keys.contains);
void _refusal(Map<Object?, Object?> reply) {
  if (_shape(reply, {'format', 'state', 'errorCode'}) &&
      reply['state'] == 'refused' &&
      nativeFillErrorCodes.contains(reply['errorCode'])) {
    throw CredentialUseFailure(reply['errorCode'] as String);
  }
}

bool _valid(List<int> bytes) {
  if (bytes.isEmpty ||
      bytes.length > 16384 ||
      bytes.any((v) => v < 0 || v > 255)) {
    return false;
  }
  try {
    final value = utf8.decode(bytes, allowMalformed: false);
    return value.isNotEmpty &&
        value.length <= 4096 &&
        !value.runes.any((v) => v < 32 || v == 127);
  } on Object {
    return false;
  }
}

// Private lifetime bookkeeping, separate from the frozen helper JSON wire.
// The token is not authentication; the XPC peer still authenticates the AppHost.
class _OwnedNativeChannel {
  _OwnedNativeChannel(this.channel);
  final MethodChannel channel;
  final String owner = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<T?> invokeMethod<T>(String method, Object? request) =>
      channel.invokeMethod<T>(method, {'owner': owner, 'request': request});
}

Future<void> _dispose(_OwnedNativeChannel channel, Duration timeout) async {
  try {
    await _call(channel, 'dispose', {}, timeout);
  } on Object {
    /* Best effort; the bridge always terminates owned connections. */
  }
}
