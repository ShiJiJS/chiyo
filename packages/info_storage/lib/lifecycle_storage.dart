part of 'info_storage.dart';

extension _EncryptedLifecycle on EncryptedInformationRepository {
  Future<InformationLifecycleReceipt?> _lifecycleReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM information_lifecycle_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0)
      throw const AccessFailure('library_changed');
    final receipt = InformationLifecycleReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (receipt.command.operationId != id)
      throw const StorageFailure('invalid_operation_receipt');
    return receipt;
  }

  Future<void> _validateLifecycle(InformationLifecycleReceipt receipt) async {
    final command = receipt.command;
    if (await _lifecycleReceipt(command.operationId) != null)
      throw const AccessFailure('operation_conflict');
    if (command.expectedCatalogVersion != null &&
        await _classificationVersion() != command.expectedCatalogVersion) {
      throw const AccessFailure('organization_conflict');
    }
    final rows = await _db
        .customSelect(
          'SELECT version FROM information_items WHERE id=?',
          variables: [Variable(command.itemId)],
        )
        .get();
    final current = rows.isEmpty ? null : rows.single.read<int>('version');
    if (command.action == InformationLifecycleAction.restoreRecycled) {
      final entries = await _db
          .customSelect(
            'SELECT payload FROM recycle_entries WHERE id=?',
            variables: [Variable(command.entryId!)],
          )
          .get();
      if (entries.isEmpty) throw const AccessFailure('recycle_unavailable');
      final entry = RecycleEntry.fromJson(
        jsonDecode(entries.single.read<String>('payload'))
            as Map<String, dynamic>,
      );
      if (entry.state != RecycleState.available ||
          !_clock().isBefore(entry.expiresAt))
        throw const AccessFailure('recycle_unavailable');
      if (entry.itemId != command.itemId ||
          entry.version != command.expectedVersion ||
          current != command.expectedCurrentVersion ||
          (entry.wholeItem && current != null) ||
          (!entry.wholeItem && current == null))
        throw const AccessFailure('recycle_conflict');
    } else if (current != command.expectedVersion) {
      throw const AccessFailure('revision_conflict');
    }
  }
}
