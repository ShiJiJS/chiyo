part of 'info_storage.dart';

extension _EncryptedCredentialBatchHistory on EncryptedInformationRepository {
  Future<void> _pruneCredentialBatchHistory(
    CredentialBatchHistoryPrune plan, {
    required void Function() validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    await _writeMetadata(() async {
      if (!await _hasCredentialBatchTables()) {
        throw const CredentialUseFailure('operation_conflict');
      }
      final requests = <CredentialUseBatch>[];
      final operations = <CredentialBatchOperation>[];
      final programs = <CredentialProgramOperation>[];
      final hasPrograms = await _hasCredentialProgramTable();
      // Read the authoritative rows inside this transaction, including any
      // operations appended after the Owner's retention preview. Never delete
      // by the cached request revision alone.
      for (final id in plan.requestIds) {
        requests.addAll(
          (await _db
                  .customSelect(
                    'SELECT id,session_binding,operation_id,payload FROM credential_batches WHERE id=?',
                    variables: [Variable(id)],
                  )
                  .get())
              .map((r) => _storedBatch(r.data)),
        );
        operations.addAll(
          (await _db
                  .customSelect(
                    'SELECT session_binding,operation_id,request_id,payload FROM credential_batch_operations WHERE request_id=?',
                    variables: [Variable(id)],
                  )
                  .get())
              .map((r) => _storedBatchOperation(r.data)),
        );
        if (hasPrograms) {
          programs.addAll(
            (await _db
                    .customSelect(
                      'SELECT execution_id,session_binding,operation_id,request_id,payload FROM credential_program_operations WHERE request_id=?',
                      variables: [Variable(id)],
                    )
                    .get())
                .map((r) => _storedProgramOperation(r.data)),
          );
        }
      }
      plan.validateAgainst(requests, operations, programs);
      validate();
      for (final id in plan.requestIds) {
        if (hasPrograms) {
          await _db.customStatement(
            'DELETE FROM credential_program_operations WHERE request_id=?',
            [id],
          );
        }
        await _db.customStatement(
          'DELETE FROM credential_batch_operations WHERE request_id=?',
          [id],
        );
        await _db.customStatement('DELETE FROM credential_batches WHERE id=?', [
          id,
        ]);
      }
    }, validate: validate);
    _credentialBatchOperations.removeWhere(
      (_, o) => plan.requestIds.contains(o.requestId),
    );
    _credentialProgramOperations.removeWhere(
      (_, o) => plan.requestIds.contains(o.requestId),
    );
    _credentialBatches.removeWhere((id, _) => plan.requestIds.contains(id));
  }
}
