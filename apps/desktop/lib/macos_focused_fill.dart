import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';

/// Candidate owner-side Adapter. Not loaded by main/bootstrap: native helper
/// packaging, validated desktop policy and an explicit storage-format migration
/// must precede capability activation. No permission request or input on create.
class MacOSFocusedFillDriver implements FocusedFillDiscoveryDriver {
  MacOSFocusedFillDriver({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 6),
  }) : _channel =
           channel ?? const MethodChannel('agent_info_manage/focused_fill'),
       assert(timeout > Duration.zero && timeout <= const Duration(seconds: 6));

  final MethodChannel _channel;
  final Duration timeout;

  @override
  Future<FocusedFillTarget> inspectTarget() async {
    final connection = _connection();
    try {
      final reply = await _invoke(_channel, 'inspect', {
        'connection': connection,
      }, timeout);
      if (_shape(reply, {'format', 'state', 'application'}) &&
          reply['state'] == 'ready') {
        return FocusedFillTarget.ready(_application(reply['application']));
      }
      return FocusedFillTarget.refused(_refusal(reply));
    } on Object {
      return const FocusedFillTarget.refused('session_unavailable');
    } finally {
      await _close(_channel, connection);
    }
  }

  @override
  Future<PreparedFocusedFill> prepare(
    FocusedFillApplication application,
  ) async {
    if (!application.executable.startsWith('/')) {
      throw const CredentialUseFailure('application_changed');
    }
    final connection = _connection();
    try {
      final reply = await _invoke(_channel, 'prepare', {
        'connection': connection,
        'application': application.toJson(),
      }, timeout);
      if (reply['state'] == 'refused') {
        throw CredentialUseFailure(_refusal(reply));
      }
      if (!_shape(reply, {'format', 'state', 'application'}) ||
          reply['state'] != 'prepared') {
        throw const CredentialUseFailure('session_unavailable');
      }
      if (!application.matches(_application(reply['application']))) {
        throw const CredentialUseFailure('application_changed');
      }
      return _MacPrepared(_channel, connection, application, timeout);
    } on CredentialUseFailure {
      await _close(_channel, connection);
      rethrow;
    } on Object {
      await _close(_channel, connection);
      throw const CredentialUseFailure('session_unavailable');
    }
  }
}

class _MacPrepared implements PreparedFocusedFill {
  _MacPrepared(this.channel, this.connection, this.application, this.timeout);
  final MethodChannel channel;
  final String connection;
  @override
  final FocusedFillApplication application;
  final Duration timeout;
  bool closed = false, sending = false;
  Future<void>? closing;

  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> utf16CodeUnits) async {
    if (closed) {
      return const FocusedFillBatchResult(
        FocusedFillState.refused,
        'target_unavailable',
      );
    }
    if (sending) {
      return const FocusedFillBatchResult(FocusedFillState.refused, 'busy');
    }
    if (!_validUnits(utf16CodeUnits)) {
      await close();
      return const FocusedFillBatchResult(
        FocusedFillState.refused,
        'unsupported_secret',
      );
    }
    sending = true;
    final bytes = Uint8List(utf16CodeUnits.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < utf16CodeUnits.length; i++) {
      view.setUint16(i * 2, utf16CodeUnits[i], Endian.little);
    }
    try {
      final reply = await _invoke(channel, 'send', {
        'connection': connection,
        'bytes': bytes,
      }, timeout);
      if (_shape(reply, {'format', 'state'}) && reply['state'] == 'sent') {
        return const FocusedFillBatchResult(FocusedFillState.sent);
      }
      if (_shape(reply, {'format', 'state', 'errorCode'}) &&
          focusedFillErrorCodes.contains(reply['errorCode'])) {
        final state = switch (reply['state']) {
          'refused' => FocusedFillState.refused,
          'partial' => FocusedFillState.partial,
          'unknown' when reply['errorCode'] == 'fill_unknown' =>
            FocusedFillState.unknown,
          _ => null,
        };
        if (state != null) {
          await close();
          return FocusedFillBatchResult(state, reply['errorCode'] as String);
        }
      }
    } on Object {
      // A message may already have reached XPC. Never retry the batch.
    } finally {
      bytes.fillRange(
        0,
        bytes.length,
        0,
      ); // Best effort; platform copies may exist.
      sending = false;
    }
    await close();
    return const FocusedFillBatchResult(
      FocusedFillState.unknown,
      'fill_unknown',
    );
  }

  @override
  Future<void> close() {
    closed = true;
    return closing ??= _close(channel, connection);
  }
}

String _connection() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Future<Map<Object?, Object?>> _invoke(
  MethodChannel channel,
  String method,
  Map<String, Object?> arguments,
  Duration timeout,
) async {
  final raw = await channel
      .invokeMethod<Object?>(method, arguments)
      .timeout(timeout);
  if (raw is! Map || raw['format'] != 1) {
    throw const CredentialUseFailure('session_unavailable');
  }
  return Map<Object?, Object?>.from(raw);
}

Future<void> _close(MethodChannel channel, String connection) async {
  try {
    await channel
        .invokeMethod<void>('close', {'connection': connection})
        .timeout(const Duration(seconds: 2));
  } on Object {
    /* terminal best effort; native connection/death/expiry also closes */
  }
}

bool _shape(Map<Object?, Object?> value, Set<String> keys) =>
    value.length == keys.length && value.keys.every(keys.contains);

String _refusal(Map<Object?, Object?> value) {
  if (_shape(value, {'format', 'state', 'errorCode'}) &&
      value['state'] == 'refused' &&
      focusedFillErrorCodes.contains(value['errorCode'])) {
    return value['errorCode'] as String;
  }
  throw const CredentialUseFailure('session_unavailable');
}

FocusedFillApplication _application(Object? value) {
  if (value is! Map) throw const CredentialUseFailure('application_changed');
  final application = FocusedFillApplication.fromJson(
    Map<String, dynamic>.from(value),
  );
  if (!application.executable.startsWith('/')) {
    throw const CredentialUseFailure('application_changed');
  }
  return application;
}

bool _validUnits(List<int> units) {
  if (units.isEmpty || units.length > 16) return false;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit < 32 || unit == 127 || unit > 0xffff) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        return false;
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
