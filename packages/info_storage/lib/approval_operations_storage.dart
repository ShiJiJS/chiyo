part of 'info_storage.dart';

extension _EncryptedApprovalOperations on EncryptedInformationRepository {
  Future<InformationApprovalReceipt?> _approvalReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated,request_id,revision FROM information_approval_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0) {
      throw const AccessFailure('library_changed');
    }
    final receipt = InformationApprovalReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (receipt.operationId != id ||
        receipt.requestId != rows.single.read<String>('request_id') ||
        receipt.revision != rows.single.read<int>('revision')) {
      throw const StorageFailure('invalid_operation_receipt');
    }
    return receipt;
  }

  Future<int> _approvalRevision(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final row = await _db
        .customSelect(
          'SELECT COALESCE(MAX(revision),0) AS revision FROM information_approval_operations WHERE request_id=? AND invalidated=0',
          variables: [Variable(id)],
        )
        .getSingle();
    return row.read<int>('revision');
  }

  Future<void> _commitApproval(
    InformationApprovalCommit change, {
    void Function()? validate,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        final receipt = change.receipt;
        if (await _approvalReceipt(receipt.operationId) != null ||
            receipt.revision !=
                await _approvalRevision(receipt.requestId) + 1) {
          throw const AccessFailure('operation_conflict');
        }
        for (final entry in change.itemVersions.entries) {
          final rows = await _db
              .customSelect(
                'SELECT version FROM information_items WHERE id=?',
                variables: [Variable(entry.key)],
              )
              .get();
          if (rows.isEmpty || rows.single.read<int>('version') != entry.value) {
            throw const AccessFailure('scope_changed');
          }
        }
        if (receipt.action == InformationApprovalAction.approve) {
          for (final f in change.grant!.fields) {
            final rows = await _db
                .customSelect(
                  'SELECT f.kind,ff.attachment_id,ff.attachment_version FROM information_fields f LEFT JOIN information_file_fields ff ON ff.field_id=f.id WHERE f.item_id=? AND f.id=?',
                  variables: [Variable(f.itemId), Variable(f.fieldId)],
                )
                .get();
            if (rows.length != 1) throw const AccessFailure('scope_changed');
            final expected =
                change.expectedFiles[FieldRef(f.itemId, f.fieldId)];
            final row = rows.single;
            if (row.read<String>('kind') == 'file'
                ? expected == null ||
                      row.readNullable<String>('attachment_id') !=
                          expected.attachmentId ||
                      row.readNullable<int>('attachment_version') !=
                          expected.attachmentVersion
                : expected != null) {
              throw const AccessFailure('scope_changed');
            }
          }
          for (final ref in change.expectedFiles.values.toSet()) {
            final version = await _attachmentVersion(ref);
            if (version == null || !version.available)
              throw const AccessFailure('attachment_missing');
            final hash = _AttachmentBackupHash();
            for (
              var offset = 0;
              offset < version.byteLength;
              offset += AttachmentBackupContainer.chunkBytes
            ) {
              hash.add(
                await _readAttachmentChunk(
                  ref,
                  offset,
                  min(
                    AttachmentBackupContainer.chunkBytes,
                    version.byteLength - offset,
                  ),
                ),
              );
            }
            if (hash.finish() != version.sha256)
              throw const AccessFailure('attachment_integrity_failed');
          }
        }
        final oldRequests = await _db
            .customSelect(
              'SELECT payload FROM request_history WHERE id=?',
              variables: [Variable(change.request.id)],
            )
            .get();
        final oldGrants = await _db
            .customSelect(
              'SELECT payload FROM grant_history WHERE id=?',
              variables: [Variable(change.grant?.id ?? '')],
            )
            .get();
        change.validatePrevious(
          oldRequests.isEmpty
              ? null
              : RequestHistory.fromJson(
                  jsonDecode(oldRequests.single.read<String>('payload'))
                      as Map<String, dynamic>,
                ),
          oldGrants.isEmpty
              ? null
              : GrantHistory.fromJson(
                  jsonDecode(oldGrants.single.read<String>('payload'))
                      as Map<String, dynamic>,
                ),
        );
        final request = change.request;
        await _db.customStatement(
          'INSERT INTO request_history(id,created_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
          [
            request.id,
            request.createdAt.toUtc().millisecondsSinceEpoch,
            jsonEncode(request.toJson()),
          ],
        );
        if (change.grant case final grant?) {
          await _db.customStatement(
            'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
            [
              grant.id,
              grant.approvedAt.toUtc().millisecondsSinceEpoch,
              jsonEncode(grant.toJson()),
            ],
          );
        }
        await _db.customStatement(
          'INSERT INTO information_approval_operations(operation_id,request_id,revision,payload) VALUES(?,?,?,?)',
          [
            receipt.operationId,
            receipt.requestId,
            receipt.revision,
            jsonEncode(receipt.toJson()),
          ],
        );
        await _checkAttachmentBackupBudget();
        validate?.call();
      });
      _requestHistory[change.request.id] = change.request;
      if (change.grant case final grant?) _history[grant.id] = grant;
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('approval_save_failed');
    }
  }
}
