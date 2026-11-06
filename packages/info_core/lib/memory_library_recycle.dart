part of 'information.dart';

extension _MemoryLibraryRecycle on MemoryInformationRepository {
  String _libraryRecycleState() => libraryRecycleStateToken(
    directories: _directories.values,
    tags: _tags.values,
    informationVersions: _items.values.map(
      (i) => [i.id, i.version, i.directoryId],
    ),
    credentials: _credentials,
    materials: _materials,
    entries: _recycle.values,
    facts: _recycleFacts,
    batches: _libraryRecycleBatches.values,
    orderDigest: _libraryOrder?.digest,
  );
  Future<LibraryRecycleReceipt> _commitLibraryRecycle(
    LibraryRecycleChange change,
  ) async {
    change.validate();
    if (_libraryRecycleState() != change.beforeToken) {
      throw const AccessFailure('library_selection_changed');
    }
    if (_libraryRecycleReceipts.containsKey(change.receipt.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    LibraryRecycleBatch.fromJson(change.batch.toJson());
    // Nothing awaits or can fail after publication starts. Disk repositories
    // implement the same boundary with a single durable transaction.
    _directories
      ..clear()
      ..addEntries(change.directories.map((d) => MapEntry(d.id, d)));
    for (final id in change.removedInformationIds) {
      _items.remove(id);
    }
    for (final item in change.items) {
      _items[item.id] = item;
    }
    _revisions.addAll(change.previous);
    for (final e in change.entries) {
      _recycle[e.id] = e;
    }
    _recycleFacts.addAll(change.facts);
    _credentials
      ..clear()
      ..addAll(change.credentials);
    _materials
      ..clear()
      ..addAll(change.materials);
    _libraryRecycleBatches[change.batch.id] = change.batch;
    if (change.order != null) _libraryOrder = change.order;
    _libraryRecycleReceipts[change.receipt.operationId] = change.receipt;
    return change.receipt;
  }
}
