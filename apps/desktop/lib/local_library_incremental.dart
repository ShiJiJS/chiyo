part of 'local_library_sync.dart';

/// The App's real transfer loop, shared by startup, manual and scheduled runs.
/// A normal pass never replaces the library or its live approvals. Network
/// awaits stay outside Owner's write barrier so local browsing remains usable.
extension LocalLibraryIncrementalSync on LocalLibrarySync {
  Future<T> _reviewConnection<T>(
    Future<T> Function(LibraryIncrementalClient) action,
  ) async {
    final stored = await readConfiguration();
    if (_busy || stored['enabled'] != true || stored['server'] == null) {
      throw const RemoteFailure('sync_busy');
    }
    final profile = ConnectionProfile.fromJson(
      Map<String, dynamic>.from(stored['server'] as Map),
    );
    final client = await _openConnection(profile);
    try {
      final remote = await LibraryIncrementalClient.connect(client);
      if (remote.identity.libraryId != stored['libraryId'] ||
          remote.identity.replicaId != stored['remoteReplicaId']) {
        throw const RemoteFailure('sync_base_changed');
      }
      return await action(remote);
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, Object?>>> reviewConflicts() => _reviewConnection((
    remote,
  ) async {
    final server = await remote.conflicts();
    if (server.isNotEmpty) {
      return [
        for (final e in server.take(1))
          {...await remote.conflict(e['cursor'] as int), 'remote': true},
      ];
    }
    return [
      for (final e in await owner.exportLibrary(() => incremental.conflicts()))
        {...e, 'remote': false},
    ];
  });

  Future<void> resolveConflict(
    Map<String, Object?> reviewed,
    bool useIncoming,
    String operationId,
  ) async {
    if (reviewed['remote'] == true) {
      await _reviewConnection(
        (remote) => remote.resolveConflict(
          cursor: reviewed['cursor'] as int,
          token: reviewed['token'] as String,
          useIncoming: useIncoming,
          operationId: operationId,
        ),
      );
    } else {
      await owner.exportLibrary(
        () => incremental.resolveConflict(
          cursor: reviewed['cursor'] as int,
          token: reviewed['token'] as String,
          useIncoming: useIncoming,
          operationId: operationId,
        ),
      );
    }
  }

  File _baselineFile(Map<String, dynamic> pending) => File(
    '${_file(libraryReplicaId(pending['fileId'])).parent.path}/baseline.encrypted',
  );

  Future<void> _saveBaseline(
    Map<String, dynamic> pending,
    LibrarySyncBaseline baseline,
    String transferKey,
  ) async {
    final file = _baselineFile(pending);
    if (await file.exists()) await file.delete();
    await AttachmentBackupContainer.write(
      path: file.path,
      recoveryKey: transferKey,
      createdAt: DateTime.now().toUtc(),
      formatVersion: 22,
      tables: {
        'sync_baseline': [
          {'baseline': baseline.toJson()},
        ],
      },
      attachments: const [],
    );
  }

  Future<LibrarySyncBaseline> _readBaseline(
    Map<String, dynamic> pending,
    LibrarySyncBaselineManifest header,
    String key,
  ) async {
    final reader = await AttachmentBackupContainer.openValidated(
      _baselineFile(pending).path,
      key,
    );
    try {
      if (reader.formatVersion != 22 ||
          reader.versions.isNotEmpty ||
          reader.tables.length != 1 ||
          reader.tables['sync_baseline']?.length != 1) {
        throw const RemoteFailure('sync_integrity_failed');
      }
      final row = reader.tables['sync_baseline']!.single;
      if (row.length != 1 || row['baseline'] is! Map) {
        throw const RemoteFailure('sync_integrity_failed');
      }
      final result = LibrarySyncBaseline.fromJson(
        Map<String, dynamic>.from(row['baseline'] as Map),
      );
      if (!header.matches(result)) {
        throw const RemoteFailure('sync_integrity_failed');
      }
      return result;
    } finally {
      reader.close();
    }
  }

  Future<OwnerClient> _openConnection(ConnectionProfile profile) =>
      OwnerClient.connect(
        address: Uri.parse(profile.address),
        token: profile.token,
        expectedServerId: profile.serverId.isEmpty ? null : profile.serverId,
        trust: profile.certificate.isEmpty
            ? null
            : (SecurityContext(
                withTrustedRoots: false,
              )..setTrustedCertificatesBytes(utf8.encode(profile.certificate))),
      );

  /// A pending upload retains exactly one encrypted file and its original key,
  /// manifest and cursor. A lost reply is queried before any local file access.
  Future<void> _resumeDelta(
    LibraryIncrementalClient remote,
    Map<String, dynamic> pending,
  ) async {
    final transfer = LibraryDeltaTransfer.fromJson(
      Map<String, dynamic>.from(pending['transfer'] as Map),
    );
    if (pending['cursor'] is! int ||
        (pending['cursor'] as int) < 1 ||
        transfer.archive.libraryId != remote.identity.libraryId) {
      throw const RemoteFailure('sync_base_changed');
    }
    final cursor = pending['cursor'] as int;
    final localReceipt = await incremental.receipt(
      transfer.sourceReplicaId,
      transfer.operationId,
      digest: transfer.archive.snapshotId,
      expectedSequence: transfer.sequence,
    );
    if (localReceipt == null ||
        localReceipt.conflict ||
        localReceipt.cursor != cursor) {
      throw const RemoteFailure('sync_operation_conflict');
    }
    await remote.uploadDelta(
      file: _file(libraryReplicaId(pending['fileId'])),
      transfer: transfer,
      transferKey: pending['transferKey'] as String,
    );
    await owner.exportLibrary(() async {
      final previous = await incremental.progress(
        remote.identity.replicaId,
        outgoing: true,
      );
      await incremental.advanceProgress(
        remote.identity.replicaId,
        expected: previous,
        next: cursor,
        outgoing: true,
      );
    });
    final stored = await readConfiguration();
    await PrivateConnectionFiles.write(_configuration, {
      ...stored,
      'delta': null,
    });
    await _settleStaging(pending);
  }

  Future<({int uploaded, int downloaded, bool needsReview})> synchronize({
    OwnerClient? connection,
    void Function()? changed,
  }) async {
    if (_busy) throw const RemoteFailure('sync_busy');
    _busy = true;
    OwnerClient? opened;
    try {
      var stored = await readConfiguration();
      if (stored['enabled'] != true) {
        return (uploaded: 0, downloaded: 0, needsReview: false);
      }
      final local = await replication.identity();
      if (stored['syncVersion'] != 2 ||
          stored['pending'] != null ||
          stored['server'] == null ||
          stored['libraryId'] != local.libraryId ||
          stored['localReplicaId'] != local.replicaId) {
        throw const RemoteFailure('sync_base_changed');
      }
      final scope = owner.captureLibraryScope();
      return await owner.inLibraryScope(scope, () async {
        final profile = ConnectionProfile.fromJson(
          Map<String, dynamic>.from(stored['server'] as Map),
        );
        final client = connection ?? (opened = await _openConnection(profile));
        if (client.serverId != profile.serverId ||
            client.address.toString() !=
                Uri.parse(profile.address).toString()) {
          throw const RemoteFailure('server_changed');
        }
        final remote = await LibraryIncrementalClient.connect(client);
        if (remote.identity.libraryId != local.libraryId ||
            remote.identity.replicaId != stored['remoteReplicaId']) {
          throw const RemoteFailure('sync_base_changed');
        }
        await owner.exportLibrary(incremental.start);
        await _cleanupUnusedStaging(stored);
        var uploaded = 0, downloaded = 0;
        if (stored['delta'] != null) {
          await _resumeDelta(
            remote,
            Map<String, dynamic>.from(stored['delta'] as Map),
          );
          uploaded++;
        }
        final localStatus = await owner.exportLibrary(incremental.status);
        var outgoing = await incremental.progress(
          remote.identity.replicaId,
          outgoing: true,
        );
        while (outgoing < localStatus.cursor) {
          final entries = (await owner.exportLibrary(
            () => incremental.after(outgoing),
          )).where((entry) => entry.cursor <= localStatus.cursor).toList();
          if (entries.isEmpty) break;
          for (final entry in entries) {
            final known = await remote.receiptFor(entry.batch);
            if (known == null) {
              final fileId = _id();
              final file = _file(fileId);
              await file.parent.create(recursive: true);
              final prepared = await owner.exportLibrary(
                () => incremental.exportDelta(
                  file.path,
                  sourceReplicaId: entry.batch.sourceReplicaId,
                  operationId: entry.batch.operationId,
                ),
              );
              final pending = <String, dynamic>{
                'fileId': fileId,
                'cursor': entry.cursor,
                'transfer': prepared.transfer.toJson(),
                'transferKey': prepared.transferKey,
              };
              stored = await readConfiguration();
              await PrivateConnectionFiles.write(_configuration, {
                ...stored,
                'delta': pending,
              });
              await _resumeDelta(remote, pending);
              uploaded++;
            } else {
              await owner.exportLibrary(
                () => incremental.advanceProgress(
                  remote.identity.replicaId,
                  expected: outgoing,
                  next: entry.cursor,
                  outgoing: true,
                ),
              );
            }
            outgoing = entry.cursor;
          }
        }
        var incoming = await incremental.progress(remote.identity.replicaId);
        final remoteStatus = await remote.status();
        while (incoming < remoteStatus.cursor) {
          final summaries = (await remote.changes(
            incoming,
          )).where((entry) => entry.cursor <= remoteStatus.cursor).toList();
          if (summaries.isEmpty) break;
          for (final summary in summaries) {
            final known = await incremental.receipt(
              summary.sourceReplicaId,
              summary.operationId,
              digest: summary.digest,
              expectedSequence: summary.sequence,
            );
            if (known == null) {
              final export = await remote.prepareDelta(summary);
              final file = _file(_id());
              await file.parent.create(recursive: true);
              try {
                await remote.transport.download(export.contents, file);
                final receipt = await owner.exportLibrary(
                  () => incremental.installDelta(
                    path: file.path,
                    transferKey: export.contents.transferKey,
                    transfer: export.transfer,
                  ),
                );
                downloaded++;
                if (!receipt.conflict) changed?.call();
              } finally {
                // Failure to release a remote temporary file cannot undo a
                // confirmed local commit; the server also has a bounded TTL.
                try {
                  await remote.transport.release(export.contents);
                } on RemoteFailure {
                  // Reclaimed by the existing server lifetime.
                }
                await _settleStaging({
                  'fileId': file.parent.uri.pathSegments
                      .where((s) => s.isNotEmpty)
                      .last,
                });
              }
            }
            await owner.exportLibrary(
              () => incremental.advanceProgress(
                remote.identity.replicaId,
                expected: incoming,
                next: summary.cursor,
              ),
            );
            incoming = summary.cursor;
          }
        }
        final current = await owner.exportLibrary(incremental.status);
        return (
          uploaded: uploaded,
          downloaded: downloaded,
          needsReview: remoteStatus.conflicts > 0 || current.conflicts > 0,
        );
      });
    } finally {
      opened?.close();
      _busy = false;
    }
  }
}
