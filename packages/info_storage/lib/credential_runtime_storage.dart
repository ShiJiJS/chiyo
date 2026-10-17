part of 'info_storage.dart';

extension _CredentialRuntimeStorage on EncryptedInformationRepository {
  Future<void> _loadRuntime() async {
    _credentialUseRequests.clear();
    _credentialExecutions.clear();
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM credential_use_requests ORDER BY rowid',
            )
            .get()) {
      var r = CredentialUseRequest.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      if (r.state == 'pending')
        r = r.changed({
          'state': 'cancelled',
          'invalidatedCode': 'grant_revoked',
        });
      else if (r.credentialApproved && !r.attemptConsumed)
        r = r.changed({'invalidatedCode': 'grant_revoked'});
      _credentialUseRequests.add(r);
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM credential_executions ORDER BY rowid',
            )
            .get()) {
      var e = CredentialExecution.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      if (e.state == 'preparing' || e.state == 'running')
        e = CredentialExecution.fromJson({
          ...e.toStorageJson(),
          'executionState': 'unknown',
          'errorCode': 'execution_unknown',
        });
      _credentialExecutions.add(e);
    }
    // Loading only persists terminal facts; it never reconstructs capabilities.
    if (_credentialUseRequests.isNotEmpty)
      await _commitRuntime(
        List.of(_credentialUseRequests),
        List.of(_credentialExecutions),
      );
  }

  Future<void> _commitRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    if (requests.map((r) => r.id).toSet().length != requests.length ||
        executions.map((e) => e.id).toSet().length != executions.length ||
        executions.any((e) => !requests.any((r) => r.id == e.requestId)))
      throw const StorageFailure('invalid_runtime_snapshot');
    try {
      await _db.transaction(() async {
        validate?.call();
        await _db.customStatement('DELETE FROM credential_executions');
        await _db.customStatement('DELETE FROM credential_use_requests');
        for (final r in requests)
          await _db.customStatement(
            'INSERT INTO credential_use_requests(id,payload) VALUES(?,?)',
            [r.id, jsonEncode(r.toJson())],
          );
        for (final e in executions)
          await _db.customStatement(
            'INSERT INTO credential_executions(id,request_id,payload) VALUES(?,?,?)',
            [e.id, e.requestId, jsonEncode(e.toStorageJson())],
          );
        if (fieldGrant != null)
          await _db.customStatement(
            'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
            [
              fieldGrant.id,
              fieldGrant.approvedAt.toUtc().millisecondsSinceEpoch,
              jsonEncode(fieldGrant.toJson()),
            ],
          );
        if (fieldRequest != null)
          await _db.customStatement(
            'INSERT INTO request_history(id,created_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
            [
              fieldRequest.id,
              fieldRequest.createdAt.toUtc().millisecondsSinceEpoch,
              jsonEncode(fieldRequest.toJson()),
            ],
          );
        validate?.call();
      });
      _credentialUseRequests
        ..clear()
        ..addAll(requests);
      _credentialExecutions
        ..clear()
        ..addAll(executions);
      if (fieldGrant != null) _history[fieldGrant.id] = fieldGrant;
      if (fieldRequest != null) _requestHistory[fieldRequest.id] = fieldRequest;
    } on CredentialUseFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('audit_save_failed');
    }
  }
}
