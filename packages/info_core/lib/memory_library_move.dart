part of 'information.dart';

extension _MemoryLibraryMove on MemoryInformationRepository {
  Future<LibraryMoveReceipt> _commitLibraryMove(
    LibraryMoveChange change,
  ) async {
    change.validate();
    if (_libraryRecycleState() != change.beforeToken) {
      throw const AccessFailure('library_selection_changed');
    }
    if (_libraryMoveReceipts.containsKey(change.receipt.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    LibraryMoveReceipt.fromJson(change.receipt.toJson());
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
    _libraryMoveReceipts[change.receipt.operationId] = change.receipt;
    if (change.order != null) _libraryOrder = change.order;
    return change.receipt;
  }
}
