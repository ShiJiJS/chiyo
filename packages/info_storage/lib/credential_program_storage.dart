part of 'info_storage.dart';

void _archiveCredentialPrograms(
  Map<String, List<Map<String, Object?>>> tables,
) {
  final requests = {
    for (final row
        in tables['credential_batches'] ?? const <Map<String, Object?>>[])
      _storedBatch(row).id: _storedBatch(row),
  };
  tables['credential_program_operations'] = [
    for (final row
        in tables['credential_program_operations'] ??
            const <Map<String, Object?>>[])
      if (requests.containsKey(row['request_id']))
        {
          ...row,
          'payload': jsonEncode(_storedProgramOperation(row).toArchiveJson()),
        },
  ];
}

void _validateBackupCredentialPrograms(
  Map<String, List<Map<String, Object?>>> tables, {
  required int formatVersion,
}) {
  try {
    final requests = {
      for (final row
          in tables['credential_batches'] ?? const <Map<String, Object?>>[])
        _storedBatch(row).id: _storedBatch(row),
    };
    final ids = <String>{},
        keys = {
          for (final r in requests.values)
            _batchOperationKey(r.sessionBinding, r.operationId),
          for (final row
              in tables['credential_batch_operations'] ??
                  const <Map<String, Object?>>[])
            _batchOperationKey(
              row['session_binding'] as String,
              row['operation_id'] as String,
            ),
        };
    for (final row
        in tables['credential_program_operations'] ??
            const <Map<String, Object?>>[]) {
      final op = _storedProgramOperation(row),
          request = requests[row['request_id']];
      if (formatVersion < 29 ||
          request == null ||
          !op.archived ||
          !ids.add(op.id) ||
          !keys.add(_batchOperationKey(op.sessionBinding, op.operationId))) {
        throw const StorageFailure('invalid_backup');
      }
      validateCredentialProgramRecord(request, op);
    }
  } on Object {
    throw const StorageFailure('invalid_backup');
  }
}

CredentialProgramOperation _storedProgramOperation(Map<String, Object?> row) {
  final operation = CredentialProgramOperation.fromStorageJson(
    decodeProtocolObject(row['payload'] as String, maxBytes: 1048576),
  );
  if (row['execution_id'] != operation.id ||
      row['request_id'] != operation.requestId ||
      row['session_binding'] != operation.sessionBinding ||
      row['operation_id'] != operation.operationId) {
    throw const StorageFailure('invalid_program_history');
  }
  return operation;
}

extension _EncryptedCredentialPrograms on EncryptedInformationRepository {
  Future<bool> _hasCredentialProgramTable() async =>
      (await _db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='credential_program_operations'",
              )
              .get())
          .isNotEmpty;
  Future<void> _createCredentialProgramTable() async {
    await _createCredentialBatchTables();
    await _requireAdmissionFormat(_credentialProgramBatchLibraryFormat);
    await _db.customStatement(
      'CREATE TABLE IF NOT EXISTS credential_program_operations('
      'execution_id TEXT NOT NULL UNIQUE,session_binding TEXT NOT NULL,operation_id TEXT NOT NULL,'
      'request_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(session_binding,operation_id),'
      'FOREIGN KEY(request_id,session_binding) REFERENCES credential_batches(id,session_binding))',
    );
  }

  Future<void> _loadCredentialPrograms() async {
    _credentialProgramOperations.clear();
    if (!await _hasCredentialProgramTable()) return;
    final marker =
        (await _db
                .customSelect(
                  'SELECT version FROM library_format WHERE singleton=1',
                )
                .getSingle())
            .read<int>('version');
    if (marker < _credentialProgramBatchLibraryFormat)
      throw const StorageFailure('unsupported_schema');
    try {
      final ids = <String>{};
      for (final row
          in await _db
              .customSelect(
                'SELECT execution_id,session_binding,operation_id,request_id,payload FROM credential_program_operations ORDER BY rowid',
              )
              .get()) {
        final operation = _storedProgramOperation(row.data),
            request = _credentialBatches[row.read<String>('request_id')];
        final key = _batchOperationKey(
          operation.sessionBinding,
          operation.operationId,
        );
        if (request == null ||
            !ids.add(operation.id) ||
            _credentialBatchOperations.containsKey(key) ||
            _credentialBatches.values.any(
              (r) =>
                  r.sessionBinding == operation.sessionBinding &&
                  r.operationId == operation.operationId,
            )) {
          throw const StorageFailure('invalid_program_history');
        }
        validateCredentialProgramRecord(request, operation);
        _credentialProgramOperations[key] = operation;
      }
    } on Object {
      throw const StorageFailure('invalid_program_history');
    }
  }

  Future<void> _commitCredentialProgramOperation(
    CredentialProgramOperation operation, {
    required int expectedRevision,
    required int requestRevision,
    required void Function() validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    final payload = jsonEncode(operation.toStorageJson());
    if (utf8.encode(payload).length > 1048576)
      throw const CredentialUseFailure('limit_exceeded');
    try {
      await _writeMetadata(() async {
        await _createCredentialProgramTable();
        final requests = await _db
            .customSelect(
              'SELECT id,session_binding,operation_id,payload FROM credential_batches WHERE id=?',
              variables: [Variable(operation.requestId)],
            )
            .get();
        if (requests.isEmpty)
          throw const CredentialUseFailure('operation_conflict');
        final request = _storedBatch(requests.single.data);
        if (request.revision != requestRevision)
          throw const CredentialUseFailure('operation_conflict');
        final prior = await _db
            .customSelect(
              'SELECT execution_id,session_binding,operation_id,request_id,payload FROM credential_program_operations WHERE session_binding=? AND operation_id=?',
              variables: [
                Variable(operation.sessionBinding),
                Variable(operation.operationId),
              ],
            )
            .get();
        validateCredentialProgramCommit(
          request,
          operation,
          prior.isEmpty ? null : _storedProgramOperation(prior.single.data),
          expectedRevision,
        );
        final collisions = await _db
            .customSelect(
              'SELECT 1 FROM credential_batches WHERE session_binding=? AND operation_id=? '
              'UNION ALL SELECT 1 FROM credential_batch_operations WHERE session_binding=? AND operation_id=? LIMIT 1',
              variables: [
                Variable(operation.sessionBinding),
                Variable(operation.operationId),
                Variable(operation.sessionBinding),
                Variable(operation.operationId),
              ],
            )
            .get();
        if (collisions.isNotEmpty)
          throw const CredentialUseFailure('operation_conflict');
        validate();
        await _db.customStatement(
          'INSERT INTO credential_program_operations(execution_id,session_binding,operation_id,request_id,payload) VALUES(?,?,?,?,?) '
          'ON CONFLICT(session_binding,operation_id) DO UPDATE SET payload=excluded.payload',
          [
            operation.id,
            operation.sessionBinding,
            operation.operationId,
            operation.requestId,
            payload,
          ],
        );
      }, validate: validate);
      _credentialProgramOperations[_batchOperationKey(
        operation.sessionBinding,
        operation.operationId,
      )] = CredentialProgramOperation.fromStorageJson(
        Map<String, dynamic>.from(operation.toStorageJson()),
      );
    } on CredentialUseFailure {
      rethrow;
    } on Object {
      throw const CredentialUseFailure('audit_unavailable');
    }
  }
}
