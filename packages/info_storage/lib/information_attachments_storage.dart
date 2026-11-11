part of 'info_storage.dart';

extension _EncryptedInformationAttachments on EncryptedInformationRepository {
  Future<T> _writeMetadata<T>(
    Future<T> Function() write, {
    void Function()? validate,
  }) => _db.transaction(() async {
    final result = await write();
    await _checkAttachmentBackupBudget();
    validate?.call();
    return result;
  });
  Future<T> _withAttachment<T>(
    InformationAttachmentRef ref,
    Future<T> Function(InformationAttachmentVersion, Stream<Uint8List>) action,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    return _db.transaction(() async {
      final version = await _attachmentVersion(ref);
      if (version == null || !version.available)
        throw const AccessFailure('attachment_missing');
      Stream<Uint8List> chunks() async* {
        for (
          var offset = 0;
          offset < version.byteLength;
          offset += AttachmentBackupContainer.chunkBytes
        ) {
          yield await _readAttachmentChunk(
            ref,
            offset,
            min(
              AttachmentBackupContainer.chunkBytes,
              version.byteLength - offset,
            ),
          );
        }
      }

      return action(version, chunks());
    });
  }

  Future<void> _reconcileAttachmentRetention(DateTime now) async {
    final versions = await _allAttachmentVersions();
    if (versions.isEmpty) return;
    if (versions.any((v) => v.seriesId != v.reference.attachmentId)) {
      await _requireAdmissionFormat(_libraryFileBranchFormat);
    }
    await _requireAdmissionFormat(_longTermAttachmentLibraryFormat);
    if (versions.any((v) => v.label.isNotEmpty || v.sourceNote.isNotEmpty)) {
      await _requireAdmissionFormat(_informationImportFileLibraryFormat);
    }
    final current = {
      for (final row
          in await _db
              .customSelect(
                'SELECT attachment_id,attachment_version FROM information_file_fields',
              )
              .get())
        InformationAttachmentRef(
          row.read<String>('attachment_id'),
          row.read<int>('attachment_version'),
        ),
    };
    final retained = <InformationAttachmentRef>{};
    void keep(InformationItem item) {
      retained.addAll(
        item.fields
            .map((f) => f.attachment)
            .whereType<InformationAttachmentRef>(),
      );
    }

    for (final r in await _db.customSelect(await _revisionRowsQuery()).get()) {
      keep(
        informationFromJson(
          jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
        ),
      );
    }
    for (final r
        in await _db
            .customSelect('SELECT payload FROM recycle_entries')
            .get()) {
      final item = RecycleEntry.fromJson(
        jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
      ).snapshot;
      if (item != null) keep(item);
    }
    final known = versions
        .where((v) => v.available)
        .map((v) => v.reference)
        .toSet();
    if (!known.containsAll(current) || !known.containsAll(retained))
      throw const AccessFailure('attachment_missing');
    final plan = retainInformationAttachments(
      versions: versions,
      current: current,
      retained: retained,
      now: now,
    );
    for (var i = 0; i < versions.length; i++) {
      final before = versions[i], after = plan[i];
      if (before.retiredAt == after.retiredAt &&
          before.purgedAt == after.purgedAt)
        continue;
      await _db.customStatement(
        'UPDATE information_attachment_versions SET metadata=?,body=CASE WHEN ?=1 THEN NULL ELSE body END WHERE attachment_id=? AND version=?',
        [
          jsonEncode(after.toPrivateJson()),
          after.available ? 0 : 1,
          after.reference.attachmentId,
          after.reference.attachmentVersion,
        ],
      );
    }
  }

  Future<InformationFileStage> _informationStage(
    String draftId,
    String stageId,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT metadata FROM information_file_stages WHERE id=? AND draft_id=?',
          variables: [Variable(stageId), Variable(draftId)],
        )
        .get();
    if (rows.length != 1) throw const AccessFailure('stage_unavailable');
    final stage = InformationFileStage.fromPrivateJson(
      jsonDecode(rows.single.read<String>('metadata')) as Map<String, dynamic>,
    );
    if (stage.id != stageId || stage.draftId != draftId)
      throw const AccessFailure('attachment_integrity_failed');
    return stage;
  }

  InformationAttachmentVersion _attachmentFromRow(Map<String, Object?> row) {
    final v = InformationAttachmentVersion.fromPrivateJson(
      jsonDecode(row['metadata'] as String) as Map<String, dynamic>,
    );
    if (v.reference.attachmentId != row['attachment_id'] ||
        v.reference.attachmentVersion != row['version'] ||
        v.byteLength != row['byte_length'] ||
        (v.available
            ? row['body_type'] != 'blob' || row['body_size'] != v.byteLength
            : row['body_type'] != 'null')) {
      throw const AccessFailure('attachment_integrity_failed');
    }
    return v;
  }

  Future<List<InformationAttachmentVersion>> _allAttachmentVersions() async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT attachment_id,version,metadata,byte_length,typeof(body) AS body_type,length(body) AS body_size FROM information_attachment_versions ORDER BY attachment_id,version',
        )
        .get();
    if (rows.length > AttachmentBackupContainer.maxVersions)
      throw const AccessFailure('attachment_capacity_exceeded');
    return List.unmodifiable(rows.map((r) => _attachmentFromRow(r.data)));
  }

  Future<List<InformationAttachmentVersion>> _attachmentVersions(
    String id,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          "SELECT attachment_id,version,metadata,byte_length,typeof(body) AS body_type,length(body) AS body_size FROM information_attachment_versions WHERE coalesce(json_extract(metadata,'\$.seriesId'),attachment_id)=coalesce((SELECT coalesce(json_extract(metadata,'\$.seriesId'),attachment_id) FROM information_attachment_versions WHERE attachment_id=? LIMIT 1),?) ORDER BY version,attachment_id LIMIT 10001",
          variables: [Variable(id), Variable(id)],
        )
        .get();
    if (rows.length > AttachmentBackupContainer.maxVersions)
      throw const AccessFailure('attachment_capacity_exceeded');
    return List.unmodifiable(rows.map((r) => _attachmentFromRow(r.data)));
  }

  Future<InformationAttachmentVersion?> _attachmentVersion(
    InformationAttachmentRef ref,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT attachment_id,version,metadata,byte_length,typeof(body) AS body_type,length(body) AS body_size FROM information_attachment_versions WHERE attachment_id=? AND version=?',
          variables: [
            Variable(ref.attachmentId),
            Variable(ref.attachmentVersion),
          ],
        )
        .get();
    return rows.isEmpty ? null : _attachmentFromRow(rows.single.data);
  }

  Future<Uint8List> _readAttachmentChunk(
    InformationAttachmentRef ref,
    int offset,
    int length,
  ) async {
    final v = await _attachmentVersion(ref);
    if (v == null || !v.available)
      throw const AccessFailure('attachment_missing');
    if (offset < 0 ||
        length < 0 ||
        length > AttachmentBackupContainer.chunkBytes ||
        offset + length > v.byteLength) {
      throw const AccessFailure('invalid_information');
    }
    // SQLite can return NULL for substr(empty_blob, 1, 0). A validated empty
    // range still belongs to an existing original.
    if (length == 0) return Uint8List(0);
    final row = await _db
        .customSelect(
          'SELECT substr(body,?,?) AS bytes FROM information_attachment_versions WHERE attachment_id=? AND version=?',
          variables: [
            Variable(offset + 1),
            Variable(length),
            Variable(ref.attachmentId),
            Variable(ref.attachmentVersion),
          ],
        )
        .getSingle();
    final bytes = row.read<Uint8List>('bytes');
    if (bytes.length != length)
      throw const AccessFailure('attachment_integrity_failed');
    return Uint8List.fromList(bytes);
  }

  Future<InformationDraftReceipt?> _draftReceipt(
    String draftId,
    String operationId,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload FROM information_draft_commits WHERE draft_id=? AND operation_id=?',
          variables: [Variable(draftId), Variable(operationId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final payload =
        jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>;
    if (payload['purged'] == true)
      throw const AccessFailure('information_purged');
    return InformationDraftReceipt.fromPrivateJson(payload);
  }

  Future<void> _checkItemAttachments(InformationItem item) async {
    final refs = item.fields
        .map((f) => f.attachment)
        .whereType<InformationAttachmentRef>()
        .toSet();
    if (refs.isEmpty) return;
    final available = (await _allAttachmentVersions())
        .where((v) => v.available)
        .map((v) => v.reference)
        .toSet();
    if (!available.containsAll(refs))
      throw const AccessFailure('attachment_missing');
  }

  Future<void> _checkStoredFileReferences() async {
    final available = (await _allAttachmentVersions())
        .where((v) => v.available)
        .map((v) => v.reference)
        .toSet();
    final items = [
      ..._items.values,
      ..._revisions.map((r) => r.item),
      ..._recycle.values.map((e) => e.snapshot).whereType<InformationItem>(),
    ];
    for (final item in items) {
      if (item.fields.any(
        (f) => f.attachment != null && !available.contains(f.attachment),
      )) {
        throw const AccessFailure('attachment_missing');
      }
    }
  }

  Future<void> _checkAttachmentBackupBudget() async {
    await _reconcileAttachmentRetention(_clock().toUtc());
    final exists = await _db
        .customSelect(
          'SELECT 1 AS n FROM information_attachment_versions LIMIT 1',
        )
        .get();
    final templates = await _db
        .customSelect('SELECT fields_json FROM field_templates')
        .get();
    final exactGrantHistory = await _db
        .customSelect(
          'SELECT 1 FROM grant_history WHERE instr(payload,\'"itemSnapshots":\')>0 LIMIT 1',
        )
        .get();
    final layoutContent = await _db
        .customSelect(
          'SELECT 1 FROM information_items WHERE layout_json IS NOT NULL '
          'UNION ALL SELECT 1 FROM information_revisions WHERE instr(payload,\'"layout":\')>0 '
          'UNION ALL SELECT 1 FROM recycle_entries WHERE instr(payload,\'"layout":\')>0 '
          'UNION ALL SELECT 1 FROM library_recycle_batches LIMIT 1',
        )
        .get();
    final retainedSnapshots =
        await _hasRevisionSnapshots() &&
        (await _db
                .customSelect(
                  'SELECT 1 FROM information_revision_snapshots LIMIT 1',
                )
                .get())
            .isNotEmpty;
    final protectedSnapshots =
        (await _db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' AND name='credential_material_snapshots'",
                )
                .get())
            .isNotEmpty &&
        (await _db
                .customSelect(
                  'SELECT 1 FROM credential_material_snapshots LIMIT 1',
                )
                .get())
            .isNotEmpty;
    if (!protectedSnapshots &&
        !retainedSnapshots &&
        exists.isEmpty &&
        exactGrantHistory.isEmpty &&
        layoutContent.isEmpty &&
        !templates.any(
          (r) => (jsonDecode(r.read<String>('fields_json')) as List).any(
            (f) => f['kind'] == 'file',
          ),
        ))
      return;
    final document = await backups._rawSnapshotDocument(
      reserveLifecycleOutcomes: true,
    );
    _checkBackupAdmissionCounts(
      document['tables'] as Map<String, List<Map<String, Object?>>>,
    );
    if (utf8.encode(jsonEncode(document)).length >
        AttachmentBackupContainer.maxPayloadBytes) {
      throw const AccessFailure('attachment_capacity_exceeded');
    }
  }

  Future<InformationDraftReceipt> _commitAttachmentDraft(
    InformationDraftChange change,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      var committed = false;
      final receipt = await _db.transaction(() async {
        if (change.operationReceipt != null &&
            (await _db
                    .customSelect(
                      'SELECT 1 FROM backup_operations WHERE operation_id IN (?,?)',
                      variables: [
                        Variable(_fileOutputKey(change.operationId)),
                        Variable(_fileOpenKey(change.operationId)),
                      ],
                    )
                    .get())
                .isNotEmpty) {
          throw const AccessFailure('operation_conflict');
        }
        if (change.operationReceipt != null &&
            await informationRecordReceipt(change.operationId) != null) {
          throw const AccessFailure('operation_conflict');
        }
        final old = await _draftReceipt(change.draftId, change.operationId);
        if (old != null) {
          if (old.inputHash != change.receipt.inputHash)
            throw const AccessFailure('operation_conflict');
          return old;
        }
        final item = change.receipt.item;
        final rows = await _db
            .customSelect(
              'SELECT version FROM information_items WHERE id=?',
              variables: [Variable(item.id)],
            )
            .get();
        if (change.previous == null
            ? rows.isNotEmpty || item.version != 1
            : rows.length != 1 ||
                  rows.single.read<int>('version') !=
                      change.previous!.item.version ||
                  item.version != change.previous!.item.version + 1) {
          throw const AccessFailure('version_conflict');
        }
        final stages = <String>{};
        for (final p in change.promotions) {
          if (!stages.add(p.stageId))
            throw const AccessFailure('stage_unavailable');
          final stage = await _informationStage(change.draftId, p.stageId),
              v = p.version;
          final versions = await _attachmentVersions(v.seriesId);
          final latest = versions.fold<int>(
            0,
            (n, v) => max(n, v.reference.attachmentVersion),
          );
          if (v.reference.attachmentVersion != latest + 1 ||
              stage.originalName != v.originalName ||
              stage.mediaType != v.mediaType ||
              stage.byteLength != v.byteLength ||
              stage.sha256 != v.sha256 ||
              !v.available ||
              v.retiredAt != null) {
            throw const AccessFailure('attachment_integrity_failed');
          }
          final hash = _AttachmentBackupHash();
          for (
            var offset = 0;
            offset < v.byteLength;
            offset += AttachmentBackupContainer.chunkBytes
          ) {
            final n = min(
              AttachmentBackupContainer.chunkBytes,
              v.byteLength - offset,
            );
            final row = await _db
                .customSelect(
                  'SELECT substr(body,?,?) AS bytes FROM information_file_stages WHERE id=? AND draft_id=?',
                  variables: [
                    Variable(offset + 1),
                    Variable(n),
                    Variable(stage.id),
                    Variable(change.draftId),
                  ],
                )
                .getSingle();
            final bytes = row.read<Uint8List>('bytes');
            if (bytes.length != n)
              throw const AccessFailure('attachment_integrity_failed');
            hash.add(bytes);
          }
          if (hash.finish() != v.sha256)
            throw const AccessFailure('attachment_integrity_failed');
          await _db.customStatement(
            'INSERT INTO information_attachment_versions(attachment_id,version,metadata,byte_length,body) SELECT ?,?,?,byte_length,body FROM information_file_stages WHERE id=? AND draft_id=?',
            [
              v.reference.attachmentId,
              v.reference.attachmentVersion,
              jsonEncode(v.toPrivateJson()),
              stage.id,
              change.draftId,
            ],
          );
        }
        await _writeItem(item);
        if (change.previous != null) await _writeRevision(change.previous!);
        await _writeRecycle(change.entries, change.facts);
        for (final id in stages) {
          await _db.customStatement(
            'DELETE FROM information_file_stages WHERE id=? AND draft_id=?',
            [id, change.draftId],
          );
        }
        if (change.operationReceipt case final operation?) {
          await _db.customStatement(
            'INSERT INTO information_record_operations(operation_id,payload) VALUES(?,?)',
            [change.operationId, jsonEncode(operation.toJson())],
          );
        } else {
          await _db.customStatement(
            'INSERT INTO information_draft_commits(draft_id,operation_id,payload) VALUES(?,?,?)',
            [
              change.draftId,
              change.operationId,
              jsonEncode(change.receipt.toPrivateJson()),
            ],
          );
        }
        await _checkAttachmentBackupBudget();
        change.validate();
        committed = true;
        return change.receipt;
      });
      final item = receipt.item;
      if (committed) {
        _items[item.id] = item;
        if (change.previous != null) _revisions.add(change.previous!);
        for (final entry in change.entries) {
          _recycle[entry.id] = entry;
        }
        _recycleFacts.addAll(change.facts);
      }
      return receipt;
    } on AccessFailure {
      rethrow;
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('attachment_save_failed');
    }
  }
}
