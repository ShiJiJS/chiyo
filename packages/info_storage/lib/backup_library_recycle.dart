part of 'info_storage.dart';

void _validateLibraryRecycleReferences(
  Iterable<LibraryRecycleBatch> batches, {
  required Map<String, RecycleEntry> entries,
  required Map<String, ManagedCredential> credentials,
  required Set<String> currentDirectories,
}) {
  final ids = <String>{}, claimedEntries = <String>{};
  for (final batch in batches) {
    if (!ids.add(batch.id)) {
      throw const FormatException('Duplicate directory recycle batch');
    }
    if (batch.state == RecycleState.available &&
        batch.directories.any((d) => currentDirectories.contains(d.id))) {
      throw const FormatException('Recycled directory is still current');
    }
    for (final r in batch.records) {
      if (r.directoryId != null &&
          batch.directoryPaths.containsKey(r.directoryId) &&
          jsonEncode(r.directoryPath) !=
              jsonEncode(batch.directoryPaths[r.directoryId])) {
        throw const FormatException('Invalid original directory path');
      }
      if (r.kind == 'information') {
        final id = batch.informationEntries[r.id]!, entry = entries[id];
        if (!claimedEntries.add(id) ||
            entry == null ||
            entry.itemId != r.id ||
            !entry.wholeItem ||
            entry.version != r.version + 1) {
          throw const FormatException('Invalid information recycle reference');
        }
      } else {
        final c = credentials[r.id];
        if (c == null ||
            batch.credentialRevisions[r.id] != r.version + 1 ||
            c.revision < batch.credentialRevisions[r.id]!) {
          throw const FormatException('Invalid credential recycle reference');
        }
      }
    }
  }
}

void _validateBackupLibraryRecycle(
  Map<String, List<Map<String, Object?>>> tables,
) {
  final rows = tables['library_recycle_batches'];
  if (rows == null) return;
  try {
    final batches = [
      for (final row in rows)
        (() {
          final batch = LibraryRecycleBatch.fromJson(_backupJson(row));
          if (row['id'] != batch.id) throw const FormatException();
          return batch;
        })(),
    ];
    _validateLibraryRecycleReferences(
      batches,
      entries: {
        for (final row in tables['recycle_entries']!)
          row['id'] as String: RecycleEntry.fromJson(_backupJson(row)),
      },
      credentials: {
        for (final row in tables['managed_credentials']!)
          row['id'] as String: ManagedCredential.fromJson(_backupJson(row)),
      },
      currentDirectories: tables['information_directories']!
          .map((r) => r['id'] as String)
          .toSet(),
    );
    _checkBackupAdmissionCounts(tables);
  } on Object {
    throw const StorageFailure('invalid_backup');
  }
}
