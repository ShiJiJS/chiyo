part of 'info_storage.dart';

extension _EncryptedLibraryRecycle on EncryptedInformationRepository {
  Future<List<LibraryRecycleBatch>> _storedLibraryRecycleBatches() async => [
    for (final row
        in await _db
            .customSelect(
              'SELECT id,payload FROM library_recycle_batches ORDER BY rowid',
            )
            .get())
      (() {
        final batch = LibraryRecycleBatch.fromJson(
          decodeProtocolObject(
            row.read<String>('payload'),
            maxBytes: AttachmentBackupContainer.maxPayloadBytes,
          ),
        );
        if (batch.id != row.read<String>('id'))
          throw const StorageFailure('invalid_recycle_batch');
        return batch;
      })(),
  ];
  Future<void> _loadLibraryRecycleBatches() async {
    final batches = await _storedLibraryRecycleBatches();
    if (batches.isNotEmpty &&
        (await _db
                    .customSelect(
                      'SELECT version FROM library_format WHERE singleton=1',
                    )
                    .getSingle())
                .read<int>('version') <
            _libraryRecycleLibraryFormat)
      throw const StorageFailure('unsupported_schema');
    _validateLibraryRecycleReferences(
      batches,
      entries: _recycle,
      credentials: {for (final c in _credentials) c.id: c},
      currentDirectories: _directories.keys.toSet(),
    );
    _libraryRecycleBatches
      ..clear()
      ..addEntries(batches.map((b) => MapEntry(b.id, b)));
  }

  Future<LibraryRecycleReceipt?> _libraryRecycleReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM library_recycle_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0)
      throw const AccessFailure('library_changed');
    final receipt = LibraryRecycleReceipt.fromJson(
      decodeProtocolObject(rows.single.read<String>('payload')),
    );
    if (receipt.operationId != id)
      throw const StorageFailure('invalid_operation_receipt');
    return receipt;
  }

  Future<String> _storedLibraryRecycleState() async {
    final directories = [
      for (final row
          in await _db
              .customSelect('SELECT * FROM information_directories')
              .get())
        InformationDirectory(
          row.read<String>('id'),
          row.read<String>('name'),
          row.readNullable<String>('parent_id'),
          row.read<int>('version'),
        ),
    ];
    final tags = [
      for (final row
          in await _db.customSelect('SELECT * FROM information_tags').get())
        InformationTag(
          row.read<String>('id'),
          row.read<String>('name'),
          row.read<int>('version'),
        ),
    ];
    final items = [
      for (final row
          in await _db
              .customSelect(
                'SELECT id,version,directory_id FROM information_items',
              )
              .get())
        <Object?>[
          row.read<String>('id'),
          row.read<int>('version'),
          row.readNullable<String>('directory_id'),
        ],
    ];
    final materials = [
      for (final row
          in await _db
              .customSelect('SELECT payload FROM credential_materials')
              .get())
        CredentialMaterial.fromStorageJson(
          decodeProtocolObject(
            row.read<String>('payload'),
            maxBytes: AttachmentBackupContainer.maxPayloadBytes,
          ),
        ),
    ];
    final entries = [
      for (final row
          in await _db
              .customSelect('SELECT payload FROM recycle_entries')
              .get())
        RecycleEntry.fromJson(
          decodeProtocolObject(
            row.read<String>('payload'),
            maxBytes: AttachmentBackupContainer.maxPayloadBytes,
          ),
        ),
    ];
    final facts = [
      for (final row
          in await _db.customSelect('SELECT payload FROM recycle_facts').get())
        RecycleFact.fromJson(
          decodeProtocolObject(
            row.read<String>('payload'),
            maxBytes: AttachmentBackupContainer.maxPayloadBytes,
          ),
        ),
    ];
    return libraryRecycleStateToken(
      directories: directories,
      tags: tags,
      informationVersions: items,
      credentials: await _storedCredentials(),
      materials: materials,
      entries: entries,
      facts: facts,
      batches: await _storedLibraryRecycleBatches(),
    );
  }

  Future<LibraryRecycleReceipt> _commitLibraryRecycle(
    LibraryRecycleChange change,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      LibraryRecycleBatch.fromJson(change.batch.toJson());
      await _db.transaction(() async {
        change.validate();
        if (await _storedLibraryRecycleState() != change.beforeToken)
          throw const AccessFailure('library_selection_changed');
        if (await _libraryRecycleReceipt(change.receipt.operationId) != null)
          throw const AccessFailure('operation_conflict');
        await _requireAdmissionFormat(_libraryRecycleLibraryFormat);
        await _db.customStatement('PRAGMA defer_foreign_keys = ON');
        for (final d in change.directories) {
          final old = _directories[d.id];
          if (old == null ||
              old.name != d.name ||
              old.parentId != d.parentId ||
              old.version != d.version)
            await _writeDirectory(d);
        }
        for (final id in change.removedInformationIds) {
          await _db.customStatement(
            'DELETE FROM information_item_tags WHERE item_id=?',
            [id],
          );
          await _db.customStatement(
            'DELETE FROM information_fields WHERE item_id=?',
            [id],
          );
          await _db.customStatement(
            'DELETE FROM information_items WHERE id=?',
            [id],
          );
        }
        for (final item in change.items) {
          await _writeItem(item);
        }
        for (final revision in change.previous) {
          await _writeRevision(revision);
        }
        _validateVault(change.credentials, change.materials);
        await _writeCredentialSnapshot(change.credentials, change.materials);
        final kept = change.directories.map((d) => d.id).toSet();
        for (final id in _directories.keys.where((id) => !kept.contains(id))) {
          await _db.customStatement(
            'DELETE FROM information_directories WHERE id=?',
            [id],
          );
        }
        await _writeRecycle(change.entries, change.facts);
        await _db.customStatement(
          'INSERT INTO library_recycle_batches(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
          [change.batch.id, jsonEncode(change.batch.toJson())],
        );
        await _db.customStatement(
          'INSERT INTO library_recycle_operations(operation_id,payload) VALUES(?,?)',
          [change.receipt.operationId, jsonEncode(change.receipt.toJson())],
        );
        await _checkAttachmentBackupBudget();
        change.validate();
      });
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
      for (final entry in change.entries) {
        _recycle[entry.id] = entry;
      }
      _recycleFacts.addAll(change.facts);
      _publishCredentialSnapshot(change.credentials, change.materials);
      _libraryRecycleBatches[change.batch.id] = change.batch;
      return change.receipt;
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('recycle_save_failed');
    }
  }
}
