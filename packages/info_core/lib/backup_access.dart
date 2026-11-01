part of 'info_core.dart';

/// Trusted owner/storage boundary, never routed through the agent transport.
/// The callbacks must complete their storage operation atomically before they
/// return; successful restore invalidates the prior runtime associations.
extension OwnerLibraryBackup on OwnerAccess {
  Future<T> exportLibrary<T>(Future<T> Function() export) =>
      _withLibrarySnapshot(export, restore: false);

  Future<T> restoreLibrary<T>(Future<T> Function() restore) =>
      _withLibrarySnapshot(restore, restore: true);

  /// Reconcile an exact durable intent while holding the Owner write lock.
  /// [previous] must only read and validate that intent's receipt: null means
  /// definitely uncommitted, and uncertainty/conflicts must throw. Callbacks
  /// must not re-enter Owner writes. Only a new atomic storage restore enters
  /// the delivery barrier and invalidates the current runtime associations.
  Future<T> restoreLibraryOnce<T extends Object>({
    required Future<T?> Function() previous,
    required Future<T> Function() restore,
  }) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final receipt = await previous();
    if (receipt != null) return receipt;
    return _runLibrarySnapshot(restore, restore: true);
  });

  Future<T> _withLibrarySnapshot<T>(
    Future<T> Function() action, {
    required bool restore,
  }) => _serialize(() => _runLibrarySnapshot(action, restore: restore));

  Future<T> _runLibrarySnapshot<T>(
    Future<T> Function() action, {
    required bool restore,
  }) async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final barrier = Completer<void>();
    _service._backupBarrier = barrier;
    _service._backupBusy = restore;
    try {
      // Stop the native endpoint before replacing its authorization library.
      // Do not await the whole task here: it may be waiting for this owner lock.
      if (restore) {
        try {
          await _service._preparedFocusedFill?.close();
        } on Object {
          throw const AccessFailure('service_unavailable');
        }
      }
      // Restore latches content delivery before replacing a library. An export
      // drains existing reads normally and leaves end/revoke/expiry effective;
      // its read-only SQL transaction captures a consistent durable snapshot.
      await Future.wait(_service._reads.toList());
      await _retryAuditStorage();
      final result = await action();
      if (restore) {
        _service._sessions.clear();
        _service._sessionBindings.clear();
        _service._endCapabilities.clear();
        _service._endedSessions.clear();
        _service._requests.clear();
        _service._grants.clear();
        _service._uncertainInformationDecisions.clear();
        _service._credentialUseSessions.clear();
        _service._executionCapabilities.clear();
        _service._pendingExecutionReceipts.clear();
        _service._failedFillAudits.clear();
        _service._pendingInformationDeliveries.clear();
        _service._retentionPreview = null;
        _service._libraryGeneration++;
      }
      return result;
    } finally {
      _service._backupBusy = false;
      _service._backupBarrier = null;
      barrier.complete();
    }
  }
}
