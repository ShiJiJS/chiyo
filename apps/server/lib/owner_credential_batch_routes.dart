import 'package:info_core/info_core.dart';
import 'package:info_workspace/owner_workspace_credential_batches.dart';
import 'package:info_workspace/workspace_source.dart';

/// Entered only from the authenticated owner queue. Agent routes intentionally
/// have no decision or acknowledgement equivalent.
final class OwnerCredentialBatchRoutes {
  OwnerCredentialBatchRoutes(this.owner);
  final OwnerAccess owner;

  Map<String, Object?> _view(CredentialUseBatch request) => {
    'protocolVersion': 3,
    'id': request.id,
    'agentName': request.agentName,
    'externalChatId': request.externalChatId,
    'chatLabel': request.chatLabel,
    'purpose': request.purpose,
    'createdAt': request.createdAt.toUtc().toIso8601String(),
    'requestExpiresAt': request.requestExpiresAt.toUtc().toIso8601String(),
    'revision': request.revision,
    'state': owner.credentialBatchState(request),
    'items': [
      for (final item in request.items)
        {
          'id': item.id,
          'credentialId': item.credentialId,
          'name': item.credentialName,
          'version': item.version,
          'destination': item.destination.toJson(),
          'decision': item.decision.name,
          'grantState': owner.credentialBatchItemState(request, item),
          'expiresAt': item.expiresAt?.toUtc().toIso8601String(),
        },
    ],
    'operations': [
      for (final operation in owner.credentialBatchOperations)
        if (operation.requestId == request.id)
          owner.credentialBatchOperationView(operation),
    ],
    if (request.programPlan != null) ...{
      'programPlan': request.programPlan!.toJson(),
      'programOperations': [
        for (final operation in owner.credentialProgramOperations)
          if (operation.requestId == request.id)
            OwnerWorkspaceCredentialBatches(
              owner,
            ).programOperationView(operation).toJson(),
      ],
    },
  };

  void _shape(Map<String, dynamic>? body, Set<String> keys) {
    if (body == null ||
        body.length != keys.length ||
        !body.keys.toSet().containsAll(keys) ||
        body['operationId'] is! String ||
        body['revision'] is! int ||
        (body['revision'] as int) < 1) {
      throw const FormatException();
    }
  }

  List<String> _ids(Object? value) {
    if (value is! List || value.any((v) => v is! String)) {
      throw const FormatException();
    }
    return value.cast<String>();
  }

  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    if (method == 'GET' && path.length == 3) {
      return (
        200,
        {'version': 1, 'requests': owner.credentialBatches.map(_view).toList()},
      );
    }
    if (path.length < 4) return (404, {'error': 'not_found'});
    final request = owner.credentialBatches
        .where((r) => r.id == path[3])
        .firstOrNull;
    if (request == null) return (404, {'error': 'not_found'});
    if (method == 'GET' && path.length == 4) return (200, _view(request));
    if (method == 'GET' && path.length == 6 && path[4] == 'operations') {
      final source = OwnerWorkspaceCredentialBatches(owner);
      return (
        200,
        request.programPlan == null
            ? source.operation(request.id, path[5]).toJson()
            : source.programOperation(request.id, path[5]).toJson(),
      );
    }
    if (method == 'POST' && path.length == 5 && path.last == 'decide') {
      _shape(body, {
        'operationId',
        'revision',
        'approvedItems',
        'lifetimeSeconds',
      });
      if (body!['lifetimeSeconds'] is! int) throw const FormatException();
      final result = await owner.decideCredentialBatch(
        request.id,
        operationId: body['operationId'] as String,
        revision: body['revision'] as int,
        approvedItems: _ids(body['approvedItems']),
        lifetime: Duration(seconds: body['lifetimeSeconds'] as int),
      );
      return (200, _view(result));
    }
    if (method == 'POST' && path.length == 5 && path.last == 'revoke') {
      _shape(body, {'operationId', 'revision', 'itemIds'});
      final result = await owner.revokeCredentialBatch(
        request.id,
        operationId: body!['operationId'] as String,
        revision: body['revision'] as int,
        itemIds: _ids(body['itemIds']),
      );
      return (200, _view(result));
    }
    if (method == 'POST' &&
        path.length == 7 &&
        path[4] == 'operations' &&
        path.last == 'acknowledge') {
      _shape(body, {'operationId', 'revision'});
      final result = await OwnerWorkspaceCredentialBatches(owner).acknowledge(
        WorkspaceCredentialBatchAcknowledgement(
          requestId: request.id,
          operationId: path[5],
          ownerOperationId: body!['operationId'] as String,
          revision: body['revision'] as int,
        ),
      );
      return (200, result.toJson());
    }
    return (404, {'error': 'not_found'});
  }
}
