part of 'info_storage.dart';

extension _EncryptedImportFiles on EncryptedInformationRepository {
  Future<void> _createImportFiles() => _db.customStatement(
    'CREATE TABLE IF NOT EXISTS information_import_files('
    'id TEXT PRIMARY KEY,session_binding TEXT NOT NULL,operation_id TEXT NOT NULL,'
    'metadata TEXT NOT NULL CHECK(length(CAST(metadata AS BLOB))<=16384),'
    'byte_length INTEGER NOT NULL CHECK(byte_length>=0 AND byte_length<=10485760),'
    'body BLOB,claimed INTEGER NOT NULL DEFAULT 0 CHECK(claimed IN(0,1)),'
    'UNIQUE(session_binding,operation_id),CHECK(body IS NULL OR length(body)=byte_length))',
  );
  Future<InformationImportUpload?> _importFileUpload(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT metadata FROM information_import_files WHERE id=?',
          variables: [Variable(id)],
        )
        .get();
    return rows.isEmpty
        ? null
        : InformationImportUpload.fromPrivateJson(
            jsonDecode(rows.single.read<String>('metadata'))
                as Map<String, dynamic>,
          );
  }

  Future<InformationImportUpload?> _importFileOperation(
    String binding,
    String operationId,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT metadata FROM information_import_files WHERE session_binding=? AND operation_id=?',
          variables: [Variable(binding), Variable(operationId)],
        )
        .get();
    return rows.isEmpty
        ? null
        : InformationImportUpload.fromPrivateJson(
            jsonDecode(rows.single.read<String>('metadata'))
                as Map<String, dynamic>,
          );
  }

  Future<void> _stageImportFile(
    InformationImportUpload upload,
    Uint8List bytes,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    if (upload.consumed ||
        upload.byteLength != bytes.length ||
        crypto.sha256.convert(bytes).toString() != upload.sha256) {
      throw const AccessFailure('attachment_integrity_failed');
    }
    final copy = Uint8List.fromList(bytes);
    try {
      await _db.transaction(() async {
        if (await _importFileOperation(
                  upload.sessionBinding,
                  upload.operationId,
                ) !=
                null ||
            await _importFileUpload(upload.id) != null) {
          throw const AccessFailure('operation_conflict');
        }
        final usage = await _fileStagingUsage();
        final retained =
            (await _db
                    .customSelect(
                      'SELECT coalesce(sum(byte_length),0) AS bytes FROM information_attachment_versions WHERE body IS NOT NULL',
                    )
                    .getSingle())
                .read<int>('bytes');
        if (usage.files >= informationFileStageLimit ||
            retained + usage.bytes + copy.length >
                informationFileStagingByteLimit) {
          throw const AccessFailure('attachment_capacity_exceeded');
        }
        await _requireAdmissionFormat(_informationImportFileLibraryFormat);
        await _db.customStatement(
          'INSERT INTO information_import_files(id,session_binding,operation_id,metadata,byte_length,body) VALUES(?,?,?,?,?,?)',
          [
            upload.id,
            upload.sessionBinding,
            upload.operationId,
            jsonEncode(upload.toPrivateJson()),
            copy.length,
            copy,
          ],
        );
      });
    } on AccessFailure {
      rethrow;
    } on sqlite.SqliteException catch (e) {
      if (e.resultCode == sqlite.SqlError.SQLITE_FULL)
        throw const AccessFailure('attachment_capacity_exceeded');
      throw const StorageFailure('file_upload_failed');
    } on Object {
      throw const StorageFailure('file_upload_failed');
    }
  }

  Future<T> _withImportFile<T>(
    String id,
    Future<T> Function(InformationImportUpload, Stream<Uint8List>) action,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    return _db.transaction(() async {
      final upload = await _importFileUpload(id);
      final rows = await _db
          .customSelect(
            'SELECT body IS NOT NULL AS available FROM information_import_files WHERE id=?',
            variables: [Variable(id)],
          )
          .get();
      if (upload == null ||
          upload.consumed ||
          rows.isEmpty ||
          rows.single.read<int>('available') != 1) {
        throw const AccessFailure('upload_unavailable');
      }
      Stream<Uint8List> chunks() async* {
        for (
          var offset = 0;
          offset < upload.byteLength;
          offset += AttachmentBackupContainer.chunkBytes
        ) {
          final row = await _db
              .customSelect(
                'SELECT substr(body,?,?) AS chunk FROM information_import_files WHERE id=?',
                variables: [
                  Variable(offset + 1),
                  Variable(
                    min(
                      AttachmentBackupContainer.chunkBytes,
                      upload.byteLength - offset,
                    ),
                  ),
                  Variable(id),
                ],
              )
              .getSingle();
          yield Uint8List.fromList(row.read<Uint8List>('chunk'));
        }
      }

      return action(upload, chunks());
    });
  }

  Future<void> _claimProposalUploads(ImportProposal proposal) =>
      _claimFileChanges(
        proposal.sessionBinding,
        proposal.items.expand((i) => i.attachments),
      );
  Future<void> _claimFileChanges(
    String binding,
    Iterable<ImportAttachmentInput> attachments,
  ) async {
    for (final a in attachments) {
      for (final version in a.versions) {
        final stored = await _importFileUpload(version.uploadId);
        if (stored == null ||
            stored.consumed ||
            stored.sessionBinding != binding ||
            version.upload == null ||
            jsonEncode(stored.toPrivateJson()) !=
                jsonEncode(version.upload!.toPrivateJson())) {
          throw const AccessFailure('upload_unavailable');
        }
        await _db.customStatement(
          'UPDATE information_import_files SET claimed=1 WHERE id=?',
          [stored.id],
        );
      }
    }
  }

  Future<void> _reconcileImportFiles() async {
    final retained = <String>{};
    for (final row
        in await _db
            .customSelect('SELECT payload FROM import_proposals')
            .get()) {
      final proposal = ImportProposal.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      for (final item in proposal.items)
        for (final a in item.attachments)
          for (final v in a.versions) retained.add(v.uploadId);
    }
    for (final row
        in await _db
            .customSelect('SELECT payload FROM update_proposals')
            .get()) {
      final proposal = UpdateProposal.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      );
      for (final a in proposal.input.attachments) {
        for (final v in a.versions) {
          retained.add(v.uploadId);
        }
      }
    }
    for (final row
        in await _db
            .customSelect(
              'SELECT metadata FROM information_import_files WHERE claimed=1 AND body IS NOT NULL',
            )
            .get()) {
      final upload = InformationImportUpload.fromPrivateJson(
        jsonDecode(row.read<String>('metadata')) as Map<String, dynamic>,
      );
      if (!retained.contains(upload.id)) {
        await _db.customStatement(
          'UPDATE information_import_files SET metadata=?,body=NULL WHERE id=?',
          [jsonEncode(upload.asConsumed().toPrivateJson()), upload.id],
        );
      }
    }
  }

  Future<void> _promoteImportFiles(
    List<InformationImportFilePromotion> promotions,
  ) async {
    for (final promotion in promotions) {
      final upload = await _importFileUpload(promotion.upload.id),
          version = promotion.version;
      final latest = (await _attachmentVersions(
        version.seriesId,
      )).fold(0, (n, v) => max(n, v.reference.attachmentVersion));
      if (upload == null ||
          upload.consumed ||
          jsonEncode(upload.toPrivateJson()) !=
              jsonEncode(promotion.upload.toPrivateJson()) ||
          version.reference.attachmentVersion != latest + 1 ||
          !version.available ||
          version.originalName != upload.originalName ||
          version.mediaType != upload.mediaType ||
          version.byteLength != upload.byteLength ||
          version.sha256 != upload.sha256) {
        throw const AccessFailure('attachment_integrity_failed');
      }
      final hash = _AttachmentBackupHash();
      var length = 0;
      await _withImportFile(upload.id, (_, chunks) async {
        await for (final chunk in chunks) {
          hash.add(chunk);
          length += chunk.length;
        }
      });
      if (length != version.byteLength || hash.finish() != version.sha256)
        throw const AccessFailure('attachment_integrity_failed');
      await _db.customStatement(
        'INSERT INTO information_attachment_versions(attachment_id,version,metadata,byte_length,body) SELECT ?,?,?,byte_length,body FROM information_import_files WHERE id=? AND body IS NOT NULL',
        [
          version.reference.attachmentId,
          version.reference.attachmentVersion,
          jsonEncode(version.toPrivateJson()),
          upload.id,
        ],
      );
    }
  }

  Future<void> _checkImportCapacity() async {
    final usage = await _fileStagingUsage();
    final retained =
        (await _db
                .customSelect(
                  'SELECT coalesce(sum(byte_length),0) AS bytes FROM information_attachment_versions WHERE body IS NOT NULL',
                )
                .getSingle())
            .read<int>('bytes');
    if (retained + usage.bytes > informationFileStagingByteLimit)
      throw const AccessFailure('attachment_capacity_exceeded');
  }

  Future<void> _pruneImportFiles(DateTime cutoff, Set<String> retained) async {
    if (_closed) throw const StorageFailure('library_closed');
    await _db.transaction(() async {
      final rows = await _db
          .customSelect('SELECT metadata FROM information_import_files')
          .get();
      for (final row in rows) {
        final upload = InformationImportUpload.fromPrivateJson(
          jsonDecode(row.read<String>('metadata')) as Map<String, dynamic>,
        );
        if (!retained.contains(upload.id) &&
            upload.createdAt.isBefore(cutoff)) {
          await _db.customStatement(
            'DELETE FROM information_import_files WHERE id=?',
            [upload.id],
          );
        }
      }
    });
  }
}
