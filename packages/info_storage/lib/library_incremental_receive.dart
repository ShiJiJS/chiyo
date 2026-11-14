part of 'info_storage.dart';

extension LibraryIncrementalReceive on LibraryIncremental {
  Future<LibrarySyncReceipt?> receipt(
    String sourceReplicaId,
    String operationId, {
    String? digest,
    int? expectedSequence,
  }) async {
    libraryReplicaId(sourceReplicaId);
    replicaOperationId(operationId);
    final state = await _state();
    final rows = await _db
        .customSelect(
          'SELECT cursor,digest,outcome,sequence FROM library_sync_feed WHERE source_id=? AND operation_id=?',
          variables: [Variable(sourceReplicaId), Variable(operationId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (digest != null && row.read<String>('digest') != digest ||
        expectedSequence != null &&
            row.read<int>('sequence') != expectedSequence) {
      throw const StorageFailure('sync_operation_conflict');
    }
    return LibrarySyncReceipt(
      libraryId: state.read<String>('library_id'),
      receiverReplicaId: state.read<String>('replica_id'),
      sourceReplicaId: sourceReplicaId,
      operationId: operationId,
      digest: row.read<String>('digest'),
      cursor: row.read<int>('cursor'),
      conflict: row.read<String>('outcome') == 'conflict',
    );
  }

  /// Validate one original before staging it in SQLCipher. Never buffer more
  /// than that existing <=10 MiB file limit, or create a plaintext disk copy.
  Future<void> cacheAttachment(
    InformationAttachmentVersion version,
    Stream<List<int>> bytes,
  ) async {
    await _state();
    if (!version.available)
      throw const StorageFailure('invalid_sync_attachment');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      if (builder.length + chunk.length > version.byteLength)
        throw const StorageFailure('sync_integrity_failed');
      builder.add(chunk);
    }
    final body = builder.takeBytes();
    if (body.length != version.byteLength ||
        crypto.sha256.convert(body).toString() != version.sha256) {
      throw const StorageFailure('sync_integrity_failed');
    }
    await _db.customStatement(
      'INSERT OR IGNORE INTO library_sync_blobs(digest,byte_length,body) VALUES(?,?,?)',
      [version.sha256, version.byteLength, body],
    );
  }

  Future<bool> hasAttachment(InformationAttachmentVersion version) async {
    if (!version.available) return true;
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM library_sync_blobs WHERE digest=? AND byte_length=? '
          'UNION ALL SELECT 1 FROM information_attachment_versions WHERE body IS NOT NULL '
          "AND byte_length=? AND json_extract(metadata,'\$.sha256')=? LIMIT 1",
          variables: [
            Variable(version.sha256),
            Variable(version.byteLength),
            Variable(version.byteLength),
            Variable(version.sha256),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  /// A queued delta can still refer to an original which local retention has
  /// since purged. Its encrypted pinned bytes remain available for that exact
  /// immutable digest, without restoring the original into the ordinary UI.
  Future<Uint8List> readAttachment(
    InformationAttachmentVersion version,
    int offset,
    int length,
  ) async {
    await _state();
    if (!version.available ||
        offset < 0 ||
        length < 1 ||
        length > AttachmentBackupContainer.chunkBytes ||
        offset + length > version.byteLength)
      throw const StorageFailure('invalid_sync_chunk');
    final ref = version.reference;
    final rows = await _db
        .customSelect(
          'SELECT substr(body,?,?) AS chunk FROM information_attachment_versions WHERE attachment_id=? AND version=? '
          "AND body IS NOT NULL AND json_extract(metadata,'\$.sha256')=? "
          'UNION ALL SELECT substr(body,?,?) AS chunk FROM library_sync_blobs WHERE digest=? AND byte_length=? LIMIT 1',
          variables: [
            Variable(offset + 1),
            Variable(length),
            Variable(ref.attachmentId),
            Variable(ref.attachmentVersion),
            Variable(version.sha256),
            Variable(offset + 1),
            Variable(length),
            Variable(version.sha256),
            Variable(version.byteLength),
          ],
        )
        .get();
    if (rows.isEmpty) throw const StorageFailure('sync_attachment_missing');
    final chunk = rows.single.read<Uint8List>('chunk');
    if (chunk.length != length)
      throw const StorageFailure('sync_integrity_failed');
    return chunk;
  }

  Future<LibrarySyncReceipt> receive(LibrarySyncBatch batch) async {
    // Reconcile an original receipt before inspecting a changed current state.
    final prior = await receipt(
      batch.sourceReplicaId,
      batch.operationId,
      digest: batch.digest,
    );
    if (prior != null) return prior;
    await project();
    void Function()? publish;
    final result = await runZoned(
      () => _db.transaction(() async {
        final known = await receipt(
          batch.sourceReplicaId,
          batch.operationId,
          digest: batch.digest,
        );
        if (known != null) return known;
        final state = await _state();
        if (batch.libraryId != state.read<String>('library_id'))
          throw const StorageFailure('sync_base_changed');
        final reused = await _db
            .customSelect(
              'SELECT 1 FROM library_sync_feed WHERE source_id=? AND sequence=?',
              variables: [
                Variable(batch.sourceReplicaId),
                Variable(batch.sequence),
              ],
            )
            .get();
        if (reused.isNotEmpty)
          throw const StorageFailure('sync_operation_conflict');
        final units = await _units();
        final versions = {
          for (final entry in units.entries) entry.key: entry.value.$1,
        };
        final decision = batch.compare(
          targetLibraryId: state.read<String>('library_id'),
          currentVersions: versions,
        );
        final current = LibraryReplicaContents._(batch.libraryId, {
          for (final entry in units.entries)
            if (entry.value.$2 != null) entry.key: entry.value.$2!,
        });
        var conflict =
            decision.action == LibrarySyncAction.conflict ||
            _ownsActiveHistory(batch) ||
            _dependencyConflict(current.replacing(batch));
        // Originals are staged even for conflicts so both candidates survive
        // disconnection and future local purging of the other version.
        for (final change in batch.changes.where(
          (c) => c.key.kind == LibrarySyncKind.attachment && c.content != null,
        )) {
          for (final raw in change.content!['attachments'] as List) {
            final version = InformationAttachmentVersion.fromPrivateJson(
              Map<String, dynamic>.from(raw as Map),
            );
            if (!await hasAttachment(version))
              throw const StorageFailure('sync_attachment_missing');
          }
        }
        if (!conflict) {
          final next = current.replacing(batch);
          final validated = next._validated(_repo._clock().toUtc());
          final inactive = _repo.backups._retain(
            validated,
            _repo._clock().toUtc(),
            restored: true,
            preserveHistory: true,
          );
          publish = _repo.backups._prepareInstall(
            inactive,
            syncKeys: batch.changes.map((c) => c.key).toSet(),
          );
          await _writeChanges(current, batch, inactive);
          await _repo._checkAttachmentBackupBudget();
          for (final change in batch.changes) {
            await _saveUnit(change.key, change.version, change.content);
          }
        }
        await _rememberParents(batch);
        if (!conflict) await _settleConflicts(batch);
        await _db.customStatement(
          'INSERT INTO library_sync_feed(source_id,operation_id,sequence,digest,payload,outcome,local_candidate) VALUES(?,?,?,?,?,?,?)',
          [
            batch.sourceReplicaId,
            batch.operationId,
            batch.sequence,
            batch.digest,
            jsonEncode(batch.toJson()),
            conflict ? 'conflict' : 'applied',
            conflict
                ? jsonEncode([
                    for (final change in batch.changes)
                      {
                        'key': change.key.toJson(),
                        'version': units[change.key]?.$1,
                        'content': units[change.key]?.$2,
                      },
                  ])
                : null,
          ],
        );
        return (await receipt(
          batch.sourceReplicaId,
          batch.operationId,
          digest: batch.digest,
        ))!;
      }),
      zoneValues: {_db._syncIncomingZone: true},
    );
    publish?.call();
    return result;
  }

  bool _ownsActiveHistory(LibrarySyncBatch batch) {
    Map<String, String>? operationRequests;
    for (final change in batch.changes.where(
      (c) => c.key.kind == LibrarySyncKind.history,
    )) {
      final id = change.key.id;
      if (id.startsWith('grant_history:') &&
          (_repo._history[id.substring('grant_history:'.length)]?.active ??
              false))
        return true;
      if (id.startsWith('credential:')) {
        final request = _repo._credentialUseRequests
            .where((r) => r.id == id.substring('credential:'.length))
            .firstOrNull;
        if (request != null &&
            request.restoredAt == null &&
            (request.state == 'pending' ||
                request.credentialApproved && request.invalidatedCode == null ||
                request.submissionOperationId != null ||
                request.revealReads.isNotEmpty ||
                _repo._credentialExecutions.any(
                  (o) => o.requestId == request.id && o.operationId != null,
                )))
          return true;
      }
      if (id.startsWith('credential-batch:')) {
        final request =
            _repo._credentialBatches[id.substring('credential-batch:'.length)];
        // Local source facts also fence duplicate operations after a grant has
        // expired. A replica's archive or retention deletion must not replace
        // them. Only the source Owner's normal retention can remove this unit.
        if (request != null && !request.archived) return true;
      }
      if (id.startsWith('credential-batch-operation:')) {
        final tables = change.content?['tables'] as Map? ?? const {};
        final requests = <String>{};
        for (final table in [
          'credential_batch_operations',
          'credential_program_operations',
        ]) {
          for (final row in tables[table] as List? ?? const []) {
            requests.add((row as Map)['request_id'] as String);
            final key = _batchOperationKey(
              row['session_binding'] as String,
              row['operation_id'] as String,
            );
            final previous = table == 'credential_batch_operations'
                ? _repo._credentialBatchOperations[key]?.requestId
                : _repo._credentialProgramOperations[key]?.requestId;
            if (previous != null) requests.add(previous);
          }
        }
        if (change.content == null) {
          operationRequests ??= {
            for (final o in _repo._credentialBatchOperations.values)
              _credentialOperationSyncKey(
                'credential_batch_operations',
                o.sessionBinding,
                o.operationId,
              ).id: o.requestId,
            for (final o in _repo._credentialProgramOperations.values)
              _credentialOperationSyncKey(
                'credential_program_operations',
                o.sessionBinding,
                o.operationId,
              ).id: o.requestId,
          };
          if (operationRequests[id] case final requestId?)
            requests.add(requestId);
        }
        if (requests.any((r) => _repo._credentialBatches[r]?.archived == false))
          return true;
      }
      if (id.startsWith('information_deliveries:')) {
        final delivery = _repo
            ._fileDeliveries[id.substring('information_deliveries:'.length)];
        if (delivery != null && delivery.restoredAt == null && delivery.runtime)
          return true;
      }
    }
    return false;
  }

  Future<void> _writeChanges(
    LibraryReplicaContents current,
    LibrarySyncBatch batch,
    BackupContents inactive,
  ) async {
    await _db.customStatement('PRAGMA defer_foreign_keys = ON');
    final next = current.replacing(batch);
    final physicalAfter = _LibrarySyncProjection.split(
      inactive._tables,
      inactive.attachments,
      preserveLocalMarkers: true,
    );
    for (final change in batch.changes.where(
      (c) => c.key.kind == LibrarySyncKind.attachment,
    )) {
      final before = current.units[change.key];
      final after = next.units[change.key];
      if (after == null) {
        for (final raw in before?['attachments'] as List? ?? const []) {
          final ref = InformationAttachmentVersion.fromPrivateJson(
            Map<String, dynamic>.from(raw as Map),
          ).reference;
          await _db.customStatement(
            'DELETE FROM information_attachment_versions WHERE attachment_id=? AND version=?',
            [ref.attachmentId, ref.attachmentVersion],
          );
        }
      } else {
        for (final raw in after['attachments'] as List) {
          await _writeAttachment(
            InformationAttachmentVersion.fromPrivateJson(
              Map<String, dynamic>.from(raw as Map),
            ),
          );
        }
      }
    }
    for (final change in batch.changes.where(
      (c) => c.key.kind != LibrarySyncKind.attachment,
    )) {
      final beforeTables =
          current.units[change.key]?['tables'] as Map? ?? const {};
      final afterTables =
          physicalAfter[change.key]?['tables'] as Map? ?? const {};
      for (final table in {
        ...beforeTables.keys,
        ...afterTables.keys,
      }.cast<String>()) {
        final physical = InformationBackups._physicalTables[table] ?? table;
        final keys = LibraryChangeJournal._keys[physical] ?? const ['id'];
        String key(Map row) => _syncJson([
          for (final column in keys)
            column == 'payload'
                ? jsonDecode(row[column] as String)
                : row[column],
        ]);
        final beforeRows = {
          for (final raw in beforeTables[table] as List? ?? const [])
            key(raw as Map): Map<String, Object?>.from(raw),
        };
        final afterRows = {
          for (final raw in afterTables[table] as List? ?? const [])
            key(raw as Map): Map<String, Object?>.from(raw),
        };
        for (final entry in beforeRows.entries.where(
          (e) => !afterRows.containsKey(e.key),
        )) {
          await _deleteRow(physical, keys, entry.value);
        }
        for (final entry in afterRows.entries.where(
          (e) => _syncJson(beforeRows[e.key]) != _syncJson(e.value),
        )) {
          await _putRow(table, physical, keys, entry.value);
        }
      }
    }
  }

  Future<void> _deleteRow(
    String table,
    List<String> keys,
    Map<String, Object?> row,
  ) async {
    if (table == 'recycle_facts') {
      final itemId = _backupJson(row)['itemId'] as String;
      final rows = await _db
          .customSelect(
            "SELECT rowid,payload FROM recycle_facts WHERE json_extract(payload,'\$.itemId')=?",
            variables: [Variable(itemId)],
          )
          .get();
      for (final existing in rows.where(
        (r) =>
            _syncJson(jsonDecode(r.read<String>('payload'))) ==
            _syncJson(_backupJson(row)),
      )) {
        await _db.customStatement('DELETE FROM recycle_facts WHERE rowid=?', [
          existing.read<int>('rowid'),
        ]);
      }
      return;
    }
    await _db.customStatement(
      'DELETE FROM $table WHERE ${keys.map((k) => '"$k"=?').join(' AND ')}',
      [for (final column in keys) row[column]],
    );
  }

  Future<void> _putRow(
    String portable,
    String physical,
    List<String> keys,
    Map<String, Object?> row,
  ) async {
    if (portable == 'information_deliveries') {
      final delivery = InformationFileDelivery.fromArchiveJson(
        _backupJson(row),
      );
      await _db.customStatement(
        'INSERT INTO information_deliveries(id,session_binding,operation_id,payload) VALUES(?,NULL,?,?) '
        'ON CONFLICT(id) DO UPDATE SET session_binding=NULL,operation_id=excluded.operation_id,payload=excluded.payload',
        [
          delivery.id,
          delivery.operationId,
          jsonEncode(delivery.toPrivateJson()),
        ],
      );
      return;
    }
    if (portable == 'credential_use_requests' &&
        _hasCredentialDeliveryRows([row])) {
      await _repo._requireAdmissionFormat(_credentialDeliveryLibraryFormat);
    }
    if (portable == 'credential_batches' ||
        portable == 'credential_batch_operations') {
      await _repo._createCredentialBatchTables();
      if (portable == 'credential_batches' &&
          _storedBatch(row).items.any((i) => i.destination.native != null)) {
        await _repo._requireAdmissionFormat(
          _nativeBatchLibraryFormat(_storedBatch(row)),
        );
      }
      if (portable == 'credential_batches' &&
          _storedBatch(row).programPlan != null) {
        await _repo._requireAdmissionFormat(
          _credentialProgramBatchLibraryFormat,
        );
      }
    }
    if (portable == 'credential_program_operations') {
      await _repo._createCredentialProgramTable();
    }
    if (portable == 'information_revision_snapshots')
      await _repo._requireAdmissionFormat(_libraryRevisionSnapshotFormat);
    if (portable == 'credential_material_snapshots')
      await _repo._requireAdmissionFormat(_libraryCredentialArchiveFormat);
    if (portable == 'grant_history') {
      await _repo._writeGrantHistory(GrantHistory.fromJson(_backupJson(row)));
      return;
    }
    final columns = InformationBackups._v29Columns[portable]!;
    final values = columns.map((c) => row[c]).toList();
    final update = columns
        .where((c) => !keys.contains(c))
        .map((c) => '"$c"=excluded."$c"')
        .join(',');
    final conflict = physical == 'recycle_facts'
        ? ''
        : ' ON CONFLICT(${keys.join(',')}) DO ${update.isEmpty ? 'NOTHING' : 'UPDATE SET $update'}';
    await _db.customStatement(
      'INSERT INTO $physical(${columns.join(',')}) VALUES(${columns.map((_) => '?').join(',')})$conflict',
      values,
    );
  }

  Future<void> _writeAttachment(InformationAttachmentVersion version) async {
    if (version.seriesId != version.reference.attachmentId) {
      await _repo._requireAdmissionFormat(_libraryFileBranchFormat);
    }
    final ref = version.reference;
    final existing = await _db
        .customSelect(
          'SELECT metadata FROM information_attachment_versions WHERE attachment_id=? AND version=?',
          variables: [
            Variable(ref.attachmentId),
            Variable(ref.attachmentVersion),
          ],
        )
        .get();
    if (existing.isNotEmpty) {
      final previous = InformationAttachmentVersion.fromPrivateJson(
        decodeProtocolObject(existing.single.read<String>('metadata')),
      );
      if (previous.sha256 != version.sha256 ||
          previous.seriesId != version.seriesId) {
        throw const StorageFailure('sync_immutable_file_changed');
      }
    }
    final body = version.available
        ? "COALESCE((SELECT body FROM information_attachment_versions WHERE body IS NOT NULL AND json_extract(metadata,'\$.sha256')=? LIMIT 1),(SELECT body FROM library_sync_blobs WHERE digest=?))"
        : 'NULL';
    await _db.customStatement(
      'INSERT INTO information_attachment_versions(attachment_id,version,metadata,byte_length,body) VALUES(?,?,?,?,$body) '
      'ON CONFLICT(attachment_id,version) DO UPDATE SET metadata=excluded.metadata,byte_length=excluded.byte_length,body=excluded.body',
      [
        ref.attachmentId,
        ref.attachmentVersion,
        jsonEncode(version.toPrivateJson()),
        version.byteLength,
        if (version.available) ...[version.sha256, version.sha256],
      ],
    );
  }
}
