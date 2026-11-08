part of 'remote_workspace_backups.dart';

extension _RemoteBackupOutputs on RemoteWorkspaceBackups {
  Future<T> _withAccess<T>(
    DeviceBackupOperations store,
    String id, {
    required bool needsOutput,
    required Future<T> Function() action,
  }) async {
    final access = await store.publication.outputStagingAccess(id);
    if (access == null) return action();
    final token = await picker.acquireAccess(
      access.toNativeArguments(),
      needsOutput: needsOutput,
    );
    try {
      return await action();
    } finally {
      await picker.releaseAccess(token);
    }
  }

  Future<void> _cleanupOne(DeviceBackupOperations store, String id) async {
    final native = store.publication;
    final root = await native.outputStagingDirectory(id);
    if (root == null) {
      await native.cleanupOutputOperation(id);
      return;
    }
    await _withAccess(
      store,
      id,
      needsOutput: false,
      action: () => native.cleanupRegisteredOutputStaging(
        id,
        releaseNative: () =>
            picker.releaseRecordedStaging(root.toPrivateJson()),
      ),
    );
  }

  Future<void> _cleanupAll(DeviceBackupOperations store) async {
    final ids = {
      ...await store.publication.pendingOutputStaging(),
      ...await store.publication.pendingOutputOperationIds(),
    };
    for (final id in ids) {
      await _cleanupOne(store, id);
    }
  }

  Future<List<int>> _download(WorkspaceBackupTransfer t) async {
    final bytes = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < t.byteLength) {
      final length = (t.byteLength - offset).clamp(1, 512 * 1024);
      final r = backupEnvelope(
        await client.request(
          'POST',
          '${RemoteWorkspaceBackups._base}/exports/${t.command.operationId}/chunks',
          {'wireVersion': 1, 'offset': offset, 'length': length},
        ),
        ['offset', 'bytes', 'byteLength', 'sha256'],
      );
      if (r['offset'] != offset ||
          r['byteLength'] != t.byteLength ||
          r['sha256'] != t.sha256 ||
          r['bytes'] is! String ||
          (r['bytes'] as String).length > ((length + 2) ~/ 3) * 4) {
        throw const FormatException();
      }
      final chunk = base64Decode(r['bytes'] as String);
      if (chunk.length != length) throw const FormatException();
      bytes.add(chunk);
      offset += length;
    }
    final result = bytes.takeBytes();
    if (sha256.convert(result).toString() != t.sha256) {
      throw const StorageFailure('backup_changed');
    }
    return result;
  }

  Future<void> _produce(
    DeviceBackupOperations store,
    WorkspaceBackupChange c,
  ) async {
    final path = files.pathFor(
      c.selection!,
      kind: c.action == WorkspaceBackupAction.saveKey
          ? WorkspaceBackupPick.keyOutput
          : WorkspaceBackupPick.archiveOutput,
    );
    late List<int> bytes;
    late Map<String, int> counts;
    if (c.action == WorkspaceBackupAction.saveKey) {
      final key = await _key();
      if (key['version'] != c.expectedVersion) {
        throw const StorageFailure('backup_version_conflict');
      }
      bytes = utf8.encode('${key['recoveryKey']}\n');
      counts = {};
      await store.bindOutput(
        c.operationId,
        sha256: key['sha256'] as String,
        byteLength: bytes.length,
        counts: counts,
      );
    } else {
      final t = backupTransferFromJson(
        await client.request(
          'POST',
          '${RemoteWorkspaceBackups._base}/exports',
          backupChangeToJson(c),
        ),
      );
      if (t.command.digest != c.digest || t.phase != 'prepared') {
        throw const StorageFailure('backup_outcome_unknown');
      }
      counts = t.counts.json;
      await store.bindOutput(
        c.operationId,
        sha256: t.sha256,
        byteLength: t.byteLength,
        counts: counts,
      );
      bytes = await _download(t);
    }
    _current();
    files.pathFor(c.selection!, kind: c.selection!.kind);
    final staging = await picker.prepareStaging(path);
    if (staging == null) {
      throw const WorkspaceFailure('unsupported', '当前系统不能创建安全的另存暂存。');
    }
    var registered = false;
    try {
      final native = store.publication;
      final version = await native.operationVersion();
      await native.registerOutputStaging(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: version,
        action: c.action == WorkspaceBackupAction.saveKey
            ? BackupOutputAction.saveKey
            : BackupOutputAction.export,
        directory: staging.directory,
        destination: path,
        stagingBookmark: staging.stagingBookmark,
      );
      registered = true;
      final prepared = '${staging.directory}/prepared';
      if (c.action == WorkspaceBackupAction.saveKey) {
        MacBackupPublicationFiles.writeRecoveryKey(prepared, bytes);
      } else {
        MacBackupPublicationFiles.writeBackupFile(prepared, bytes);
      }
      final publication = MacBackupPublicationFiles.prepare(prepared, path);
      await native.prepareOutputOperation(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: version,
        action: c.action == WorkspaceBackupAction.saveKey
            ? BackupOutputAction.saveKey
            : BackupOutputAction.export,
        publication: publication,
      );
      _current();
      files.pathFor(c.selection!, kind: c.selection!.kind);
      await native.publishOutputOperation(
        c.operationId,
        afterPublication: staging.stagingBookmark == null
            ? null
            : () async {
                await native.recordOutputBookmark(
                  c.operationId,
                  await picker.outputBookmark(staging),
                );
              },
      );
    } finally {
      try {
        if (registered) {
          await _cleanupOne(store, c.operationId);
        } else {
          await picker.releaseStaging(staging);
        }
      } catch (_) {
        /* Keep uncertain anchors and durable cleanup facts. */
      }
    }
  }
}

extension RemoteBackupRecoveryAccess on RemoteWorkspaceBackups {
  Future<bool> _recoverAccess(String id) async {
    final store = await _store();
    final entry = await store.read(id);
    if (entry == null ||
        !entry.intent.pending ||
        await store.publication.outputOperationPhase(id) !=
            BackupOutputPhase.publishing) {
      throw const StorageFailure('backup_outcome_unknown');
    }
    final access = await store.publication.outputStagingAccess(id);
    if (access == null) throw const StorageFailure('backup_outcome_unknown');
    final bookmark = await picker.reselectOutput(access.destination);
    if (bookmark == null) return false;
    return _run(() async {
      final now = await store.read(id);
      if (now == null ||
          !now.intent.pending ||
          now.intent.digest != entry.intent.digest) {
        throw const StorageFailure('backup_outcome_unknown');
      }
      await store.publication.recordOutputBookmark(id, bookmark);
      return true;
    }, uncertain: true);
  }
}
