part of 'info_storage.dart';

String _batchOperationKey(String binding, String id) => '$binding\u0000$id';

CredentialUseBatch _storedBatch(Map<String, Object?> row) {
  final request = CredentialUseBatch.fromJson(
    decodeProtocolObject(row['payload'] as String, maxBytes: 1048576),
  );
  if (row['id'] != request.id ||
      row['session_binding'] != request.sessionBinding ||
      row['operation_id'] != request.operationId) {
    throw const StorageFailure('invalid_batch_history');
  }
  return request;
}

CredentialBatchOperation _storedBatchOperation(Map<String, Object?> row) {
  final operation = CredentialBatchOperation.fromJson(
    decodeProtocolObject(row['payload'] as String, maxBytes: 1048576),
  );
  if (row['request_id'] != operation.requestId ||
      row['session_binding'] != operation.sessionBinding ||
      row['operation_id'] != operation.operationId) {
    throw const StorageFailure('invalid_batch_history');
  }
  return operation;
}

void _archiveCredentialBatches(
  Map<String, List<Map<String, Object?>>> tables,
  DateTime now,
) {
  final requests = <String, CredentialUseBatch>{};
  tables['credential_batches'] = [
    for (final row
        in tables['credential_batches'] ?? const <Map<String, Object?>>[])
      if (_storedBatch(row).decisions.isNotEmpty)
        (() {
          final request = CredentialUseBatch.fromJson({
            ..._storedBatch(row).toJson(),
            'archived': true,
          });
          requests[request.id] = request;
          return {...row, 'payload': jsonEncode(request.toJson())};
        })(),
  ];
  tables['credential_batch_operations'] = [
    for (final row
        in tables['credential_batch_operations'] ??
            const <Map<String, Object?>>[])
      if (requests.containsKey(row['request_id']))
        (() {
          var operation = _storedBatchOperation(row);
          if ({
            CredentialBatchOperationState.checking,
            CredentialBatchOperationState.dispatched,
          }.contains(operation.state)) {
            operation = operation.changed(
              state: CredentialBatchOperationState.unknown,
              errorCode: 'execution_unknown',
            );
          }
          return {...row, 'payload': jsonEncode(operation.toJson())};
        })(),
  ];
}

void _validateBackupCredentialBatches(
  Map<String, List<Map<String, Object?>>> tables, {
  required int formatVersion,
}) {
  try {
    final requests = <String, CredentialUseBatch>{};
    final submissions = <String>{};
    for (final row
        in tables['credential_batches'] ?? const <Map<String, Object?>>[]) {
      final r = _storedBatch(row);
      if (r.programPlan != null && formatVersion < 29 ||
          r.items.any((i) => i.destination.native != null) &&
              formatVersion < 30 ||
          !r.archived ||
          r.decisions.isEmpty ||
          requests.containsKey(r.id) ||
          !submissions.add(
            _batchOperationKey(r.sessionBinding, r.operationId),
          )) {
        throw const StorageFailure('invalid_backup');
      }
      requests[r.id] = r;
    }
    final operations = <String>{};
    for (final row
        in tables['credential_batch_operations'] ??
            const <Map<String, Object?>>[]) {
      final o = _storedBatchOperation(row), r = requests[o.requestId];
      final key = _batchOperationKey(o.sessionBinding, o.operationId);
      if (r == null ||
          o.sessionBinding != r.sessionBinding ||
          submissions.contains(key) ||
          !operations.add(key) ||
          {
            CredentialBatchOperationState.checking,
            CredentialBatchOperationState.dispatched,
          }.contains(o.state) ||
          o.itemIds.any((id) => !r.items.any((i) => i.id == id))) {
        throw const StorageFailure('invalid_backup');
      }
    }
  } on Object {
    throw const StorageFailure('invalid_backup');
  }
}

extension _EncryptedCredentialBatches on EncryptedInformationRepository {
  Future<void> _createCredentialBatchTables() async {
    await _requireAdmissionFormat(_credentialBatchLibraryFormat);
    await _db.customStatement(
      'CREATE TABLE IF NOT EXISTS credential_batches('
      'id TEXT PRIMARY KEY,session_binding TEXT NOT NULL,operation_id TEXT NOT NULL,payload TEXT NOT NULL,'
      'UNIQUE(session_binding,operation_id),UNIQUE(id,session_binding))',
    );
    await _db.customStatement(
      'CREATE TABLE IF NOT EXISTS credential_batch_operations('
      'session_binding TEXT NOT NULL,operation_id TEXT NOT NULL,request_id TEXT NOT NULL,payload TEXT NOT NULL,'
      'PRIMARY KEY(session_binding,operation_id),'
      'FOREIGN KEY(request_id,session_binding) REFERENCES credential_batches(id,session_binding))',
    );
    await _ensureCredentialHistorySyncCapture();
  }

  Future<bool> _hasCredentialBatchTables() async {
    final tables = await _db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('credential_batches','credential_batch_operations')",
        )
        .get();
    if (tables.length == 1) throw const StorageFailure('invalid_batch_history');
    return tables.length == 2;
  }

  Future<void> _loadCredentialBatches() async {
    _credentialBatches.clear();
    _credentialBatchOperations.clear();
    if (!await _hasCredentialBatchTables()) return;
    final marker =
        (await _db
                .customSelect(
                  'SELECT version FROM library_format WHERE singleton=1',
                )
                .getSingle())
            .read<int>('version');
    if (marker < _credentialBatchLibraryFormat)
      throw const StorageFailure('unsupported_schema');
    try {
      for (final row
          in await _db
              .customSelect(
                'SELECT id,session_binding,operation_id,payload FROM credential_batches ORDER BY rowid',
              )
              .get()) {
        final batch = _storedBatch(row.data);
        if (batch.items.any((i) => i.destination.native != null) &&
            marker < _nativeFillLibraryFormat) {
          throw const StorageFailure('unsupported_schema');
        }
        if (batch.programPlan != null &&
            marker < _credentialProgramBatchLibraryFormat) {
          throw const StorageFailure('unsupported_schema');
        }
        _credentialBatches[batch.id] = batch;
      }
      for (final row
          in await _db
              .customSelect(
                'SELECT request_id,session_binding,operation_id,payload FROM credential_batch_operations ORDER BY rowid',
              )
              .get()) {
        final operation = _storedBatchOperation(row.data);
        final batch = _credentialBatches[operation.requestId];
        if (batch == null ||
            batch.sessionBinding != operation.sessionBinding ||
            operation.itemIds.any(
              (id) => !batch.items.any((i) => i.id == id),
            ) ||
            _credentialBatches.values.any(
              (r) =>
                  r.sessionBinding == operation.sessionBinding &&
                  r.operationId == operation.operationId,
            )) {
          throw const StorageFailure('invalid_batch_history');
        }
        _credentialBatchOperations[_batchOperationKey(
              operation.sessionBinding,
              operation.operationId,
            )] =
            operation;
      }
      // These new operations have App-local one-time material proofs. A restart
      // preserves approved scopes, but cannot infer that unreported input never
      // happened or recreate an input capability from a stored operation ID.
      for (final old in List<CredentialBatchOperation>.of(
        _credentialBatchOperations.values,
      )) {
        if (!{
          CredentialBatchOperationState.checking,
          CredentialBatchOperationState.dispatched,
        }.contains(old.state))
          continue;
        final request = _credentialBatches[old.requestId]!;
        final next = old.changed(
          state: CredentialBatchOperationState.unknown,
          errorCode: 'execution_unknown',
        );
        await _commitCredentialBatch(
          request,
          expectedRevision: request.revision,
          operation: next,
          expectedOperationRevision: old.revision,
          validate: () {},
        );
      }
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('invalid_batch_history');
    }
  }

  Future<void> _commitCredentialBatch(
    CredentialUseBatch request, {
    required int expectedRevision,
    required void Function() validate,
    CredentialBatchOperation? operation,
    int? expectedOperationRevision,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    CredentialUseBatch.fromJson(Map<String, dynamic>.from(request.toJson()));
    if (operation != null)
      CredentialBatchOperation.fromJson(
        Map<String, dynamic>.from(operation.toJson()),
      );
    try {
      await _writeMetadata(() async {
        await _createCredentialBatchTables();
        if (request.items.any((i) => i.destination.native != null)) {
          await _requireAdmissionFormat(_nativeFillLibraryFormat);
        }
        if (request.programPlan != null) {
          await _requireAdmissionFormat(_credentialProgramBatchLibraryFormat);
        }
        final found = await _db
            .customSelect(
              'SELECT id,session_binding,operation_id,payload FROM credential_batches WHERE id=?',
              variables: [Variable(request.id)],
            )
            .get();
        final previous = found.isEmpty ? null : _storedBatch(found.single.data);
        CredentialBatchOperation? oldOperation;
        if (operation != null) {
          final rows = await _db
              .customSelect(
                'SELECT request_id,session_binding,operation_id,payload FROM credential_batch_operations WHERE session_binding=? AND operation_id=?',
                variables: [
                  Variable(operation.sessionBinding),
                  Variable(operation.operationId),
                ],
              )
              .get();
          if (rows.isNotEmpty)
            oldOperation = _storedBatchOperation(rows.single.data);
        }
        validateCredentialBatchCommit(
          request,
          previous,
          expectedRevision,
          operation: operation,
          previousOperation: oldOperation,
          expectedOperationRevision: expectedOperationRevision,
        );
        if (await _hasCredentialProgramTable()) {
          for (final id in {
            if (previous == null) request.operationId,
            if (operation != null) operation.operationId,
          }) {
            final collision = await _db
                .customSelect(
                  'SELECT 1 FROM credential_program_operations WHERE session_binding=? AND operation_id=? LIMIT 1',
                  variables: [Variable(request.sessionBinding), Variable(id)],
                )
                .get();
            if (collision.isNotEmpty)
              throw const CredentialUseFailure('operation_conflict');
          }
        }
        if (previous == null) {
          final collision = await _db
              .customSelect(
                'SELECT 1 FROM credential_batch_operations WHERE session_binding=? AND operation_id=?',
                variables: [
                  Variable(request.sessionBinding),
                  Variable(request.operationId),
                ],
              )
              .get();
          if (collision.isNotEmpty)
            throw const CredentialUseFailure('operation_conflict');
        }
        if (operation != null) {
          final collision = await _db
              .customSelect(
                'SELECT 1 FROM credential_batches WHERE session_binding=? AND operation_id=?',
                variables: [
                  Variable(operation.sessionBinding),
                  Variable(operation.operationId),
                ],
              )
              .get();
          if (collision.isNotEmpty)
            throw const CredentialUseFailure('operation_conflict');
        }
        validate();
        if (previous == null || previous.revision != request.revision) {
          await _db.customStatement(
            'INSERT INTO credential_batches(id,session_binding,operation_id,payload) VALUES(?,?,?,?) '
            'ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
            [
              request.id,
              request.sessionBinding,
              request.operationId,
              jsonEncode(request.toJson()),
            ],
          );
        }
        if (operation != null) {
          await _db.customStatement(
            'INSERT INTO credential_batch_operations(session_binding,operation_id,request_id,payload) VALUES(?,?,?,?) '
            'ON CONFLICT(session_binding,operation_id) DO UPDATE SET payload=excluded.payload',
            [
              operation.sessionBinding,
              operation.operationId,
              operation.requestId,
              jsonEncode(operation.toJson()),
            ],
          );
        }
      }, validate: validate);
      _credentialBatches[request.id] = CredentialUseBatch.fromJson(
        Map<String, dynamic>.from(request.toJson()),
      );
      if (operation != null) {
        _credentialBatchOperations[_batchOperationKey(
          operation.sessionBinding,
          operation.operationId,
        )] = CredentialBatchOperation.fromJson(
          Map<String, dynamic>.from(operation.toJson()),
        );
      }
    } on CredentialUseFailure {
      rethrow;
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('batch_save_failed');
    }
  }
}
