part of 'info_storage.dart';

extension _EncryptedClassification on EncryptedInformationRepository {
  Future<int> _classificationVersion() async {
    if (_closed) throw const StorageFailure('library_closed');
    final row = await _db
        .customSelect(
          'SELECT version FROM information_classification_state WHERE singleton=1',
        )
        .getSingle();
    return row.read<int>('version');
  }

  Future<InformationClassificationReceipt?> _classificationReceipt(
    String id,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM information_classification_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0)
      throw const AccessFailure('library_changed');
    final receipt = InformationClassificationReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (receipt.operationId != id)
      throw const StorageFailure('invalid_operation_receipt');
    return receipt;
  }

  Future<InformationClassificationReceipt> _commitClassification(
    InformationClassificationChange change,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      final receipt = await _db.transaction(() async {
        change.validate();
        if (await _classificationVersion() != change.command.expectedVersion)
          throw const AccessFailure('organization_conflict');
        if (await _classificationReceipt(change.command.operationId) != null)
          throw const AccessFailure('operation_conflict');
        if (change.directory != null) await _writeDirectory(change.directory!);
        if (change.tag != null) await _writeTag(change.tag!);
        for (final item in change.items) {
          await _writeItem(item);
        }
        for (final revision in change.previous) {
          await _writeRevision(revision);
        }
        if (change.command.action == InformationClassificationAction.delete) {
          if (change.command.kind == InformationClassificationKind.directory) {
            await _db.customStatement(
              'DELETE FROM information_directories WHERE id=?',
              [change.targetId],
            );
          } else {
            await _db.customStatement(
              'DELETE FROM information_item_tags WHERE tag_id=?',
              [change.targetId],
            );
            await _db.customStatement(
              'DELETE FROM information_tags WHERE id=?',
              [change.targetId],
            );
          }
        }
        final result = change.receipt(await _classificationVersion());
        await _db.customStatement(
          'INSERT INTO information_classification_operations(operation_id,payload) VALUES(?,?)',
          [result.operationId, jsonEncode(result.toJson())],
        );
        await _checkAttachmentBackupBudget();
        change.validate();
        return result;
      });
      if (change.directory != null)
        _directories[change.targetId] = change.directory!;
      if (change.tag != null) _tags[change.targetId] = change.tag!;
      if (change.command.action == InformationClassificationAction.delete) {
        if (change.command.kind == InformationClassificationKind.directory) {
          _directories.remove(change.targetId);
        } else {
          _tags.remove(change.targetId);
        }
      }
      for (final item in change.items) {
        _items[item.id] = item;
      }
      _revisions.addAll(change.previous);
      return receipt;
    } catch (error) {
      if (error is AccessFailure) rethrow;
      throw const StorageFailure('save_failed');
    }
  }
}
