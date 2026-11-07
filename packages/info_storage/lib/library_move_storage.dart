part of 'info_storage.dart';

extension _EncryptedLibraryMove on EncryptedInformationRepository {
  Future<LibraryMoveReceipt?> _libraryMoveReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM library_move_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0) {
      throw const AccessFailure('library_changed');
    }
    final receipt = LibraryMoveReceipt.fromJson(
      decodeProtocolObject(
        rows.single.read<String>('payload'),
        maxBytes: AttachmentBackupContainer.maxPayloadBytes,
      ),
    );
    if (receipt.operationId != id) {
      throw const StorageFailure('invalid_operation_receipt');
    }
    return receipt;
  }

  Future<LibraryMoveReceipt> _commitLibraryMove(
    LibraryMoveChange change,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      LibraryMoveReceipt.fromJson(change.receipt.toJson());
      await _db.transaction(() async {
        change.validate();
        if (await _storedLibraryRecycleState() != change.beforeToken) {
          throw const AccessFailure('library_selection_changed');
        }
        if (await _libraryMoveReceipt(change.receipt.operationId) != null) {
          throw const AccessFailure('operation_conflict');
        }
        for (final d in change.directories) {
          await _writeDirectory(d);
        }
        for (final item in change.items) {
          await _writeItem(item);
        }
        for (final revision in change.previous) {
          await _writeRevision(revision);
        }
        // Same material/version/use-generation: classification never grants,
        // revokes or reissues a credential, and never copies its bytes.
        await _writeCredentialSnapshot(
          change.credentials,
          _credentialMaterials,
        );
        if (change.order != null) await _writeLibraryOrder(change.order!);
        await _db.customStatement(
          'INSERT INTO library_move_operations(operation_id,payload) VALUES(?,?)',
          [change.receipt.operationId, jsonEncode(change.receipt.toJson())],
        );
        await _checkAttachmentBackupBudget();
        change.validate();
      });
      for (final d in change.directories) {
        _directories[d.id] = d;
      }
      for (final item in change.items) {
        _items[item.id] = item;
      }
      _revisions.addAll(change.previous);
      _credentials
        ..clear()
        ..addAll(change.credentials);
      if (change.order != null) _libraryOrder = change.order;
      return change.receipt;
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('move_save_failed');
    }
  }
}
