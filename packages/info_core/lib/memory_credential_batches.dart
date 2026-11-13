part of 'information.dart';

extension _MemoryCredentialBatches on MemoryInformationRepository {
  Future<void> _commitCredentialBatch(
    CredentialUseBatch request, {
    required int expectedRevision,
    required void Function() validate,
    CredentialBatchOperation? operation,
    int? expectedOperationRevision,
  }) async {
    final key = operation == null
        ? null
        : '${operation.sessionBinding}\u0000${operation.operationId}';
    final old = _credentialBatches[request.id];
    validateCredentialBatchCommit(
      request,
      old,
      expectedRevision,
      operation: operation,
      previousOperation: _credentialBatchOperations[key],
      expectedOperationRevision: expectedOperationRevision,
    );
    if (old == null &&
            (_credentialBatches.values.any(
                  (r) =>
                      r.sessionBinding == request.sessionBinding &&
                      r.operationId == request.operationId,
                ) ||
                _credentialBatchOperations.containsKey(
                  '${request.sessionBinding}\u0000${request.operationId}',
                )) ||
        operation != null &&
            _credentialBatches.values.any(
              (r) =>
                  r.sessionBinding == operation.sessionBinding &&
                  r.operationId == operation.operationId,
            )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    validate();
    _credentialBatches[request.id] = CredentialUseBatch.fromJson(
      Map<String, dynamic>.from(request.toJson()),
    );
    if (operation != null) {
      _credentialBatchOperations[key!] = CredentialBatchOperation.fromJson(
        Map<String, dynamic>.from(operation.toJson()),
      );
    }
  }
}
