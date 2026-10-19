part of 'info_storage.dart';

extension _CredentialRuntimeStorage on EncryptedInformationRepository {
  Future<void> _loadSshTrust() async {
    final rows = await _db
        .customSelect('SELECT payload FROM ssh_host_trust WHERE id=1')
        .get();
    _sshHostTrust = rows.isEmpty
        ? null
        : SshHostTrustSnapshot.fromStorageJson(
            jsonDecode(rows.single.read<String>('payload'))
                as Map<String, dynamic>,
          );
  }

  Future<void> _saveSshTrust(SshHostTrustSnapshot? snapshot) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        await _db.customStatement('DELETE FROM ssh_host_trust');
        if (snapshot != null) {
          await _db.customStatement(
            'INSERT INTO ssh_host_trust(id,payload) VALUES(1,?)',
            [jsonEncode(snapshot.toStorageJson())],
          );
        }
      });
      _sshHostTrust = snapshot;
    } on Object {
      throw const StorageFailure('ssh_trust_save_failed');
    }
  }

  Future<void> _loadRuntime() async {
    _credentialUseRequests.clear();
    _credentialExecutions.clear();
    _focusedFillOperations.clear();
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM credential_runtime_requests ORDER BY rowid',
            )
            .get()) {
      var r = CredentialUseRequest.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      if (r.state == 'pending') {
        r = r.changed({
          'state': 'cancelled',
          'invalidatedCode': 'grant_revoked',
        });
      } else if (r.credentialApproved && !r.attemptConsumed)
        r = r.changed({'invalidatedCode': 'grant_revoked'});
      _credentialUseRequests.add(r);
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT payload FROM credential_operations ORDER BY rowid',
            )
            .get()) {
      var e = CredentialExecution.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      if (e.state == 'preparing' || e.state == 'running') {
        e = CredentialExecution.fromJson({
          ...e.toStorageJson(),
          'executionState': 'unknown',
          'errorCode': 'execution_unknown',
          'cleanupState': e.materialLease == null
              ? e.cleanupState
              : 'needs_check',
        });
      }
      _credentialExecutions.add(e);
    }
    await _loadFocusedFills();
    _validateRuntimeSnapshot(
      _credentialUseRequests,
      _credentialExecutions,
      _focusedFillOperations,
    );
    // Loading only persists terminal facts; it never reconstructs capabilities.
    if (_credentialUseRequests.isNotEmpty) {
      await _commitRuntime(
        List.of(_credentialUseRequests),
        List.of(_credentialExecutions),
      );
    }
  }

  Future<void> _commitRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    List<FocusedFillOperation>? fills,
    void Function()? validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    final fillSnapshot = fills ?? List.of(_focusedFillOperations);
    _validateRuntimeSnapshot(requests, executions, fillSnapshot);
    try {
      await _db.transaction(() async {
        validate?.call();
        await _db.customStatement('DELETE FROM credential_focused_fills');
        await _db.customStatement('DELETE FROM credential_operations');
        await _db.customStatement('DELETE FROM credential_runtime_requests');
        for (final r in requests) {
          await _db.customStatement(
            'INSERT INTO credential_runtime_requests(id,payload) VALUES(?,?)',
            [r.id, jsonEncode(r.toJson())],
          );
        }
        for (final e in executions) {
          await _db.customStatement(
            'INSERT INTO credential_operations(id,request_id,payload) VALUES(?,?,?)',
            [e.id, e.requestId, jsonEncode(e.toStorageJson())],
          );
        }
        for (final fill in fillSnapshot) {
          await _db.customStatement(
            'INSERT INTO credential_focused_fills(id,request_id,payload) VALUES(?,?,?)',
            [fill.id, fill.requestId, jsonEncode(fill.toStorageJson())],
          );
        }
        if (fieldGrant != null) {
          await _db.customStatement(
            'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
            [
              fieldGrant.id,
              fieldGrant.approvedAt.toUtc().millisecondsSinceEpoch,
              jsonEncode(fieldGrant.toJson()),
            ],
          );
        }
        if (fieldRequest != null) {
          await _db.customStatement(
            'INSERT INTO request_history(id,created_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
            [
              fieldRequest.id,
              fieldRequest.createdAt.toUtc().millisecondsSinceEpoch,
              jsonEncode(fieldRequest.toJson()),
            ],
          );
        }
        validate?.call();
      });
      _credentialUseRequests
        ..clear()
        ..addAll(requests);
      _credentialExecutions
        ..clear()
        ..addAll(executions);
      _focusedFillOperations
        ..clear()
        ..addAll(fillSnapshot);
      if (fieldGrant != null) _history[fieldGrant.id] = fieldGrant;
      if (fieldRequest != null) _requestHistory[fieldRequest.id] = fieldRequest;
    } on CredentialUseFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('audit_save_failed');
    }
  }
}

void _validateRuntimeSnapshot(
  List<CredentialUseRequest> requests,
  List<CredentialExecution> executions, [
  List<FocusedFillOperation> fills = const [],
]) {
  Never invalid() => throw const StorageFailure('invalid_runtime_snapshot');
  final byId = {for (final r in requests) r.id: r};
  if (byId.length != requests.length ||
      executions.map((e) => e.id).toSet().length != executions.length)
    invalid();
  final operations = <String, Set<String>>{},
      executionById = <String, CredentialExecution>{};
  for (final e in executions) {
    final r = byId[e.requestId];
    if (r == null ||
        r.isFocusedFill ||
        e.protocolVersion != r.protocolVersion ||
        !{1, 2}.contains(e.protocolVersion))
      invalid();
    if (e.protocolVersion == 2) {
      if (!r.credentialApproved ||
          e.operationId == null ||
          e.operationId!.length > 128 ||
          !RegExp(r'^[!-~]+$').hasMatch(e.operationId!) ||
          !operations.putIfAbsent(r.id, () => {}).add(e.operationId!) ||
          e.operationFingerprint == null ||
          !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(e.operationFingerprint!) ||
          e.operationPlan?.identity == null ||
          e.operationPlan!.executable.byteLength < 1 ||
          e.operationPlan!.executable.modifiedMicros < 0 ||
          !RegExp(
            r'^sha256:[0-9a-f]{64}$',
          ).hasMatch(e.operationPlan!.executable.sha256) ||
          e.operationPlan!.receiver != r.plan.receiver)
        invalid();
      final values = [...e.operationPlan!.argv, ...e.operationPlan!.env.values];
      if (values.any(
        (v) =>
            {LaunchValueKind.secret, LaunchValueKind.file}.contains(v.kind) &&
            v.value != r.alias,
      ))
        invalid();
    }
    executionById[e.id] = e;
  }
  _validateFocusedFillSnapshot(requests, executions, fills);
  for (final r in requests) {
    if (!{1, 2}.contains(r.protocolVersion)) invalid();
    if (r.isFocusedFill) continue;
    if (r.protocolVersion == 2 &&
        (r.attemptConsumed ||
            (r.executionId == null
                ? r.attemptedAt != null || operations.containsKey(r.id)
                : executionById[r.executionId]?.requestId != r.id ||
                      r.attemptedAt == null)))
      invalid();
  }
}
