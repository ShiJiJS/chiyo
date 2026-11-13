import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';

final class AgentDeviceIdentity {
  const AgentDeviceIdentity(this.id, this.name, this.generation);
  final String id, name, generation;
}

/// A private proof minted by the core (session, end capability or grant).
/// Only a digest is stored in the device binding index.
final class AgentDeviceCapability {
  const AgentDeviceCapability(this.kind, this.value);
  final String kind, value;
  String get key {
    if (!const {
          'session',
          'end',
          'grant',
          'file-cleanup',
          'credential-execution',
          'credential-fill',
          'credential-batch',
        }.contains(kind) ||
        value.isEmpty ||
        value.length > 2000) {
      throw const AccessFailure('invalid_request');
    }
    return '$kind:${sha256.convert(utf8.encode(value))}';
  }
}

/// The raw secret is returned only by the authenticated owner enrollment path.
/// Device catalog responses must use metadata(), never serialize this object.
final class EnrolledAgentDevice {
  const EnrolledAgentDevice(this.identity, this.secret);
  final AgentDeviceIdentity identity;
  final String secret;
  String get bearer => '${identity.id}.$secret';
}

/// Encrypted, independent device credentials. This authenticates an Agent
/// connection, not information access and never an owner approval decision.
final class AgentDeviceRegistry {
  AgentDeviceRegistry(this._repository);
  final ServerStateRepository _repository;
  Future<void> _writes = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  String _secret(int bytes) {
    final r = Random.secure();
    return base64Url
        .encode(List.generate(bytes, (_) => r.nextInt(256)))
        .replaceAll('=', '');
  }

  Map<String, dynamic> _map(ServerStateSnapshot snapshot, String key) {
    final value = snapshot.payload[key];
    if (!snapshot.payload.containsKey(key)) return {};
    if (value is! Map) throw const AccessFailure('invalid_device_state');
    return Map<String, dynamic>.from(value);
  }

  void _operationId(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value))
      throw const AccessFailure('invalid_request');
  }

  Map<String, dynamic> _row(dynamic value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['secret'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value['secret'] as String) ||
        value['revoked'] is! bool) {
      throw const AccessFailure('invalid_device_state');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<EnrolledAgentDevice> enroll(String operationId, String name) =>
      _serialize(() async {
        _operationId(operationId);
        if (name.trim().isEmpty ||
            name.length > 200 ||
            name.codeUnits.any((c) => c < 32))
          throw const AccessFailure('invalid_request');
        final snapshot = await _repository.openServerState();
        final devices = _map(snapshot, 'agentDevices'),
            operations = _map(snapshot, 'agentDeviceOperations');
        final previous = operations[operationId];
        if (previous != null) {
          if (previous is! Map ||
              previous['action'] != 'enroll' ||
              previous['name'] != name)
            throw const AccessFailure('operation_conflict');
          final id = previous['deviceId'] as String;
          final row = _row(devices[id]);
          if (row['revoked'] as bool)
            throw const AccessFailure('device_revoked');
          return EnrolledAgentDevice(
            AgentDeviceIdentity(id, row['name'] as String, snapshot.generation),
            row['secret'] as String,
          );
        }
        if (devices.length >= 128) throw const AccessFailure('device_limit');
        final id = _secret(16), secret = _secret(32);
        devices[id] = {'name': name, 'secret': secret, 'revoked': false};
        operations[operationId] = {
          'action': 'enroll',
          'name': name,
          'deviceId': id,
        };
        await _repository.commitServerState(snapshot, {
          ...snapshot.payload,
          'agentDevices': devices,
          'agentDeviceOperations': operations,
        });
        return EnrolledAgentDevice(
          AgentDeviceIdentity(id, name, snapshot.generation),
          secret,
        );
      });

  AgentDeviceIdentity _authenticate(
    ServerStateSnapshot snapshot,
    String bearer,
  ) {
    final parts = bearer.split('.');
    if (parts.length != 2 ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(parts[0]) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(parts[1]))
      throw const AccessFailure('unauthorized');
    final raw = _map(snapshot, 'agentDevices')[parts[0]];
    if (raw == null) throw const AccessFailure('unauthorized');
    final row = _row(raw);
    // Compare fixed-length digests, retaining no secret in diagnostics.
    final expected = sha256.convert(utf8.encode(row['secret'] as String)).bytes;
    final supplied = sha256.convert(utf8.encode(parts[1])).bytes;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ supplied[i];
    }
    if (diff != 0 || row['revoked'] as bool)
      throw const AccessFailure('unauthorized');
    return AgentDeviceIdentity(
      parts[0],
      row['name'] as String,
      snapshot.generation,
    );
  }

  Future<AgentDeviceIdentity> authenticate(String bearer) async =>
      _authenticate(await _repository.openServerState(), bearer);

  /// Check every request against current encrypted state, including after
  /// asynchronous reads. A restore changes generation and removes all bindings.
  Future<AgentDeviceIdentity> authorize(
    String bearer, {
    String? generation,
    Iterable<AgentDeviceCapability> capabilities = const [],
  }) async {
    final snapshot = await _repository.openServerState();
    final device = _authenticate(snapshot, bearer);
    if (generation != null && generation != snapshot.generation) {
      throw const AccessFailure('unauthorized');
    }
    final bindings = _map(snapshot, 'agentCapabilityBindings');
    for (final capability in capabilities) {
      if (bindings[capability.key] != device.id) {
        throw const AccessFailure('unauthorized');
      }
    }
    return device;
  }

  Future<void> bindCapabilities(
    String bearer,
    String generation,
    Iterable<AgentDeviceCapability> capabilities,
  ) => _serialize(() async {
    final snapshot = await _repository.openServerState();
    final device = _authenticate(snapshot, bearer);
    if (snapshot.generation != generation) {
      throw const AccessFailure('unauthorized');
    }
    final bindings = _map(snapshot, 'agentCapabilityBindings');
    for (final capability in capabilities) {
      final key = capability.key;
      if (bindings.containsKey(key) && bindings[key] != device.id) {
        throw const AccessFailure('unauthorized');
      }
      bindings[key] = device.id;
    }
    await _repository.commitServerState(snapshot, {
      ...snapshot.payload,
      'agentCapabilityBindings': bindings,
    });
  });

  Future<List<Map<String, Object?>>> metadata() async {
    final snapshot = await _repository.openServerState();
    return [
      for (final entry in _map(snapshot, 'agentDevices').entries)
        {
          'id': entry.key,
          'name': _row(entry.value)['name'],
          'revoked': _row(entry.value)['revoked'],
        },
    ];
  }

  Future<void> revoke(String operationId, String deviceId) =>
      _serialize(() async {
        _operationId(operationId);
        final snapshot = await _repository.openServerState();
        final devices = _map(snapshot, 'agentDevices'),
            operations = _map(snapshot, 'agentDeviceOperations');
        final prior = operations[operationId];
        if (prior != null) {
          if (prior is! Map ||
              prior['action'] != 'revoke' ||
              prior['deviceId'] != deviceId)
            throw const AccessFailure('operation_conflict');
          return;
        }
        if (!devices.containsKey(deviceId))
          throw const AccessFailure('not_found');
        final row = _row(devices[deviceId]);
        devices[deviceId] = {...row, 'revoked': true};
        operations[operationId] = {'action': 'revoke', 'deviceId': deviceId};
        await _repository.commitServerState(snapshot, {
          ...snapshot.payload,
          'agentDevices': devices,
          'agentDeviceOperations': operations,
        });
      });
}
