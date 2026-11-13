import 'dart:convert';
import 'info_core.dart';

/// Shared local/App and authenticated device transport. The caller supplies the
/// verified device identity; a body cannot nominate another executing device.
/// Proof/material replies belong exclusively to the private App execution path.
final class CredentialBatchProtocol {
  CredentialBatchProtocol(this.agent, this.deviceId);
  final AgentAccess agent;
  final String deviceId;
  static const base = '/credential-use/batch';
  static const sessionPaths = {
    '$base/request',
    '$base/status',
    '$base/begin',
    '$base/operation',
  };
  static const proofPaths = {
    '$base/material',
    '$base/authorize',
    '$base/finish',
  };
  static bool handles(String path) =>
      sessionPaths.contains(path) || proofPaths.contains(path);

  void _shape(
    Map<String, dynamic> body,
    Set<String> required, [
    Set<String> optional = const {},
  ]) {
    if (!body.keys.toSet().containsAll(required) ||
        body.keys.any(
          (key) => !required.contains(key) && !optional.contains(key),
        )) {
      throw const CredentialUseFailure('unknown_field');
    }
  }

  String _text(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty || value.length > 2000) {
      throw const CredentialUseFailure('invalid_type');
    }
    return value;
  }

  List<String> _ids(Object? value) {
    if (value is! List || value.any((v) => v is! String)) {
      throw const CredentialUseFailure('invalid_type');
    }
    return value.cast<String>();
  }

  Future<Map<String, Object?>> dispatch(
    String path,
    Map<String, dynamic> body,
  ) async {
    switch (path) {
      case '$base/request':
        _shape(body, {'sessionSecret', 'operationId', 'input'});
        if (body['input'] is! Map<String, dynamic>) {
          throw const CredentialUseFailure('invalid_type');
        }
        final session = _text(body, 'sessionSecret');
        final request = await agent.requestCredentialBatch(
          session,
          deviceId,
          CredentialBatchInput.fromJson(body['input'] as Map<String, dynamic>),
          operationId: _text(body, 'operationId'),
        );
        return agent.credentialBatchStatus(session, deviceId, request.id);
      case '$base/status':
        _shape(body, {'sessionSecret', 'requestId'});
        return agent.credentialBatchStatus(
          _text(body, 'sessionSecret'),
          deviceId,
          _text(body, 'requestId'),
        );
      case '$base/begin':
        _shape(
          body,
          {'sessionSecret', 'requestId', 'operationId'},
          {'itemIds'},
        );
        final claim = await agent.beginCredentialBatchOperation(
          _text(body, 'sessionSecret'),
          deviceId,
          _text(body, 'requestId'),
          operationId: _text(body, 'operationId'),
          itemIds: body.containsKey('itemIds') ? _ids(body['itemIds']) : null,
        );
        return {
          ...claim.toPublicJson(),
          if (claim.privateProof != null) 'privateProof': claim.privateProof,
        };
      case '$base/operation':
        _shape(body, {'sessionSecret', 'operationId'});
        return agent.credentialBatchOperationStatus(
          _text(body, 'sessionSecret'),
          deviceId,
          _text(body, 'operationId'),
        );
      case '$base/material':
        _shape(body, {'privateProof', 'observations'});
        if (body['observations'] is! Map<String, dynamic>) {
          throw const CredentialUseFailure('invalid_type');
        }
        final observations = <String, CredentialBatchDestination>{};
        for (final entry
            in (body['observations'] as Map<String, dynamic>).entries) {
          if (entry.value is! Map<String, dynamic>) {
            throw const CredentialUseFailure('invalid_type');
          }
          observations[entry.key] = CredentialBatchDestination.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
        final material = await agent.claimCredentialBatchMaterials(
          deviceId,
          _text(body, 'privateProof'),
          observations,
        );
        return {
          'protocolVersion': 3,
          'status': 'ok',
          'materials': material.bytes.map(
            (k, v) => MapEntry(k, base64Encode(v)),
          ),
        };
      case '$base/authorize':
        _shape(body, {'privateProof'});
        await agent.authorizeCredentialBatchInput(
          deviceId,
          _text(body, 'privateProof'),
        );
        return {'protocolVersion': 3, 'status': 'ok'};
      case '$base/finish':
        _shape(body, {'privateProof', 'state', 'itemResults', 'errorCode'});
        final state = CredentialBatchOperationState.values
            .where((s) => s.name == body['state'])
            .firstOrNull;
        if (state == null ||
            body['itemResults'] is! Map<String, dynamic> ||
            (body['itemResults'] as Map).values.any((v) => v is! String) ||
            body['errorCode'] != null && body['errorCode'] is! String) {
          throw const CredentialUseFailure('invalid_type');
        }
        return (await agent.finishCredentialBatchOperation(
          deviceId,
          _text(body, 'privateProof'),
          state,
          itemResults: Map<String, String>.from(body['itemResults'] as Map),
          errorCode: body['errorCode'] as String?,
        )).toPublicJson();
      default:
        throw const CredentialUseFailure('unsupported_capability');
    }
  }
}
