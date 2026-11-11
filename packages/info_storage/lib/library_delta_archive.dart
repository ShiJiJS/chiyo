part of 'info_storage.dart';

final class PreparedLibraryDelta {
  PreparedLibraryDelta._(this.transfer, this.transferKey);
  final LibraryDeltaTransfer transfer;
  final String transferKey;
}

final class PreparedSynchronizedLibrary {
  PreparedSynchronizedLibrary._(this.initial, this.baseline);
  final PreparedLibraryTransfer initial;
  final LibrarySyncBaseline baseline;
}

extension LibraryIncrementalArchives on LibraryIncremental {
  /// Both the content archive and its versions/watermark are captured in one
  /// SQL transaction, also excluding background audit writes between them.
  Future<PreparedSynchronizedLibrary> exportInitialWithBaseline(
    String path,
  ) async {
    await start();
    return _db.transaction(() async {
      await project();
      final initial = await replication.exportInitial(path);
      final initialBase = await baseline(initial.transfer.snapshotId);
      return PreparedSynchronizedLibrary._(initial, initialBase);
    });
  }

  /// Prepare additive private tables outside installation so a later failure
  /// cannot leave the live connection expecting rolled-back schema. The
  /// imported content, baseline, progress and receipt then commit together.
  Future<LibraryInitialReceipt> installInitialWithBaseline({
    required String path,
    required String transferKey,
    required String operationId,
    required LibraryInitialTransfer transfer,
    required LibrarySyncBaseline baseline,
    required String expectedSourceReplicaId,
  }) async {
    final prior = await initialReceipt(
      operationId: operationId,
      transfer: transfer,
      baseline: baseline,
      expectedSourceReplicaId: expectedSourceReplicaId,
    );
    if (prior != null) return prior;
    if (!await replication.empty())
      throw const StorageFailure('recipient_not_empty');
    await start();
    return replication.installInitial(
      path: path,
      transferKey: transferKey,
      operationId: operationId,
      transfer: transfer,
      initializeIncremental: (contents) =>
          start(initialContents: contents, baseline: baseline),
    );
  }

  Future<LibraryInitialReceipt?> initialReceipt({
    required String operationId,
    required LibraryInitialTransfer transfer,
    required LibrarySyncBaseline baseline,
    required String expectedSourceReplicaId,
  }) async {
    if (baseline.sourceReplicaId != expectedSourceReplicaId ||
        baseline.libraryId != transfer.libraryId ||
        baseline.snapshotId != transfer.snapshotId) {
      throw const StorageFailure('sync_base_changed');
    }
    final prior = await replication.receipt(operationId, transfer);
    if (prior != null) {
      final state = await _state();
      if (state.readNullable<String>('initial_baseline_digest') !=
          baseline.digest) {
        throw const StorageFailure('sync_operation_conflict');
      }
      return prior;
    }
    return null;
  }

  /// Query the exact installed content and baseline digest without requiring
  /// an already-cleaned archive or retransmitting its potentially large map.
  Future<LibraryInitialReceipt?> initialReceiptManifest({
    required String operationId,
    required LibraryInitialTransfer transfer,
    required LibrarySyncBaselineManifest baseline,
  }) async {
    if (baseline.libraryId != transfer.libraryId ||
        baseline.snapshotId != transfer.snapshotId) {
      throw const StorageFailure('sync_base_changed');
    }
    final prior = await replication.receipt(operationId, transfer);
    if (prior == null) return null;
    final state = await _state();
    if (state.readNullable<String>('initial_baseline_digest') !=
        baseline.digest)
      throw const StorageFailure('sync_operation_conflict');
    return prior;
  }

  /// Caller holds Owner's snapshot barrier. Reuse the existing encrypted,
  /// validated chunk container; no source database key enters this archive.
  Future<PreparedLibraryDelta> exportDelta(
    String path, {
    required String sourceReplicaId,
    required String operationId,
  }) async {
    libraryReplicaId(sourceReplicaId);
    replicaOperationId(operationId);
    await project();
    final rows = await _db
        .customSelect(
          "SELECT payload FROM library_sync_feed WHERE source_id=? AND operation_id=? AND outcome='applied'",
          variables: [Variable(sourceReplicaId), Variable(operationId)],
        )
        .get();
    if (rows.isEmpty) throw const StorageFailure('sync_change_missing');
    final batch = LibrarySyncBatch.decode(rows.single.read<String>('payload'));
    final versions = _deltaVersions(batch);
    final random = Random.secure();
    final key =
        'aim-recovery-v1:${base64Url.encode(List.generate(32, (_) => random.nextInt(256)))}';
    await AttachmentBackupContainer.write(
      path: path,
      recoveryKey: key,
      createdAt: _repo._clock().toUtc(),
      formatVersion: 22,
      tables: {
        'sync_delta': [
          {'payload': jsonEncode(batch.toJson())},
        ],
      },
      attachments: [
        for (final version in versions)
          AttachmentBackupSource(
            version,
            read: version.available
                ? (offset, length) => readAttachment(version, offset, length)
                : null,
          ),
      ],
    );
    return PreparedLibraryDelta._(
      LibraryDeltaTransfer(
        archive: LibraryInitialTransfer(
          libraryId: batch.libraryId,
          snapshotId: batch.digest,
          archiveDigest: await _repo.backups._restoreArchiveDigest(path),
          byteLength: await File(path).length(),
          contentFormat: 22,
        ),
        sourceReplicaId: batch.sourceReplicaId,
        operationId: batch.operationId,
        sequence: batch.sequence,
      ),
      key,
    );
  }

  /// Stage originals privately and atomically apply their matching metadata.
  /// A known receipt can be returned after the file was cleaned or lost.
  Future<LibrarySyncReceipt> installDelta({
    required String path,
    required String transferKey,
    required LibraryDeltaTransfer transfer,
  }) async {
    final state = await _state();
    if (transfer.archive.libraryId != state.read<String>('library_id'))
      throw const StorageFailure('sync_base_changed');
    final prior = await receipt(
      transfer.sourceReplicaId,
      transfer.operationId,
      digest: transfer.archive.snapshotId,
      expectedSequence: transfer.sequence,
    );
    if (prior != null) return prior;
    if (await File(path).length() != transfer.archive.byteLength ||
        await _repo.backups._restoreArchiveDigest(path) !=
            transfer.archive.archiveDigest) {
      throw const StorageFailure('sync_integrity_failed');
    }
    final reader = await AttachmentBackupContainer.openValidated(
      path,
      transferKey,
    );
    try {
      if (reader.formatVersion != 22 ||
          reader.tables.length != 1 ||
          reader.tables['sync_delta']?.length != 1) {
        throw const StorageFailure('unsupported_sync_format');
      }
      final raw = reader.tables['sync_delta']!.single;
      if (raw.length != 1 || raw['payload'] is! String)
        throw const StorageFailure('unsupported_sync_format');
      final batch = LibrarySyncBatch.decode(raw['payload'] as String);
      if (batch.libraryId != transfer.archive.libraryId ||
          batch.digest != transfer.archive.snapshotId ||
          batch.sourceReplicaId != transfer.sourceReplicaId ||
          batch.operationId != transfer.operationId ||
          batch.sequence != transfer.sequence) {
        throw const StorageFailure('sync_integrity_failed');
      }
      final expected = _deltaVersions(batch);
      final actual = {
        for (final version in reader.versions)
          version.reference: _syncJson(version.toPrivateJson()),
      };
      if (actual.length != expected.length ||
          expected.any(
            (v) => actual[v.reference] != _syncJson(v.toPrivateJson()),
          )) {
        throw const StorageFailure('sync_integrity_failed');
      }
      for (final version in expected) {
        if (!await hasAttachment(version)) {
          await cacheAttachment(
            version,
            reader.readAttachment(version.reference),
          );
        }
      }
      return await receive(batch);
    } finally {
      reader.close();
    }
  }
}

List<InformationAttachmentVersion> _deltaVersions(LibrarySyncBatch batch) {
  final versions = <InformationAttachmentRef, InformationAttachmentVersion>{};
  for (final change in batch.changes.where(
    (c) => c.key.kind == LibrarySyncKind.attachment && c.content != null,
  )) {
    final raw = change.content!['attachments'];
    if (raw is! List || raw.length != 1)
      throw const StorageFailure('invalid_sync_unit');
    final version = InformationAttachmentVersion.fromPrivateJson(
      Map<String, dynamic>.from(raw.single as Map),
    );
    if (versions.containsKey(version.reference))
      throw const StorageFailure('invalid_sync_unit');
    versions[version.reference] = version;
  }
  return versions.values.toList()..sort(
    (a, b) => _syncJson(
      a.reference.toJson(),
    ).compareTo(_syncJson(b.reference.toJson())),
  );
}
