part of 'info_storage.dart';

extension _DesktopPreferencesStorage on EncryptedInformationRepository {
  Future<DesktopPreferencesReceipt?> _desktopReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM desktop_preference_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0)
      throw const AccessFailure('library_changed');
    final receipt = DesktopPreferencesReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (receipt.operationId != id)
      throw const StorageFailure('invalid_operation_receipt');
    return receipt;
  }

  Future<void> _commitDesktop(
    DesktopPreferencesReceipt receipt,
    DesktopHistoryCleanup cleanup,
    void Function() validate,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        validate();
        final rows = await _db
            .customSelect(
              "SELECT value FROM settings WHERE name='desktopPreferencesVersion'",
            )
            .get();
        if ((rows.isEmpty ? 1 : rows.single.read<int>('value')) !=
            receipt.expectedVersion)
          throw const AccessFailure('conflict');
        for (final entry in cleanup.tables.entries) {
          for (final id in entry.value) {
            await _db.customStatement('DELETE FROM ${entry.key} WHERE id=?', [
              id,
            ]);
          }
        }
        for (final entry in receipt.preferences.settings.entries) {
          await _db.customStatement(
            'INSERT INTO settings(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value',
            [entry.key, entry.value],
          );
        }
        await _db.customStatement(
          'INSERT INTO desktop_preference_operations(operation_id,payload) VALUES(?,?)',
          [receipt.operationId, jsonEncode(receipt.toJson())],
        );
        await _checkAttachmentBackupBudget();
        validate();
      });
      _settings.addAll(receipt.preferences.settings);
      _history.removeWhere(
        (id, _) => cleanup.tables['grant_history']!.contains(id),
      );
      _requestHistory.removeWhere(
        (id, _) => cleanup.tables['request_history']!.contains(id),
      );
      _accesses.removeWhere(
        (id, _) => cleanup.tables['access_records']!.contains(id),
      );
      _organizationTasks.removeWhere(
        (id, _) => cleanup.tables['organization_tasks']!.contains(id),
      );
      _credentialUseRequests.removeWhere(
        (r) => cleanup.tables['credential_runtime_requests']!.contains(r.id),
      );
      _credentialExecutions.removeWhere(
        (e) => cleanup.tables['credential_operations']!.contains(e.id),
      );
      _focusedFillOperations.removeWhere(
        (f) => cleanup.tables['credential_focused_fills']!.contains(f.id),
      );
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('save_failed');
    }
  }
}
