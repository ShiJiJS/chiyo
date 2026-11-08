part of 'owner_backup_routes.dart';

extension _OwnerBackupOutputs on OwnerBackupRoutes {
  WorkspaceBackupChange _remoteCommand(BackupRemoteOutput r) {
    final c = WorkspaceBackupChange(
      operationId: r.operationId,
      action: r.action == BackupOutputAction.saveKey
          ? WorkspaceBackupAction.saveKey
          : WorkspaceBackupAction.export,
      expectedVersion: r.expectedVersion,
      selection: WorkspaceBackupResource(
        id: r.resourceId,
        name: r.fileName,
        version: r.resourceVersion,
        kind: r.action == BackupOutputAction.saveKey
            ? WorkspaceBackupPick.keyOutput
            : WorkspaceBackupPick.archiveOutput,
      ),
    );
    if (c.digest != r.commandDigest)
      throw const StorageFailure('invalid_backup_operation_receipt');
    return c;
  }

  WorkspaceBackupReceipt _remoteReceipt(BackupRemoteOutput r) {
    final c = _remoteCommand(r);
    if (r.phase != BackupRemoteOutputPhase.saved)
      throw const StorageFailure('backup_outcome_unknown');
    return WorkspaceBackupReceipt(
      operationId: r.operationId,
      commandDigest: r.commandDigest,
      action: c.action,
      expectedVersion: r.expectedVersion,
      version: r.version,
      resource: WorkspaceBackupResource(
        id: 'output_${sha256.convert(utf8.encode(r.operationId))}',
        name: r.fileName,
        kind: r.action == BackupOutputAction.saveKey
            ? WorkspaceBackupPick.keyInput
            : WorkspaceBackupPick.archiveInput,
      ),
      counts: r.action == BackupOutputAction.export ? _counts(r.counts) : null,
    );
  }

  WorkspaceBackupTransfer _transfer(BackupRemoteOutput r) {
    if (r.action != BackupOutputAction.export)
      throw const StorageFailure('operation_conflict');
    return WorkspaceBackupTransfer(
      command: _remoteCommand(r),
      phase: r.phase.name,
      sha256: r.contentDigest,
      byteLength: r.byteLength,
      counts: _counts(r.counts),
    );
  }

  String _artifactPath(String id) {
    backupHash(id);
    return '${directory.path}/out-$id/archive';
  }

  Future<void> _cleanupOutputs({bool forceOrphans = false}) async {
    if (!_outputCleanupRequested && !forceOrphans) return;
    final entries = {
      for (final r in await backups.remoteOutputs())
        if (r.artifactId != null) r.artifactId!: r,
    };
    var pendingOrphans = false;
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((v) => v.isNotEmpty).last;
      if (!RegExp(r'^out-[0-9a-f]{64}$').hasMatch(name) ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.directory)
        continue;
      final r = entries[name.substring(4)];
      if (r?.phase == BackupRemoteOutputPhase.prepared) continue;
      if (r == null &&
          !forceOrphans &&
          DateTime.now().difference((await entity.stat()).modified) <
              OwnerBackupRoutes.lifetime) {
        pendingOrphans = true;
        continue;
      }
      await entity.delete(recursive: true);
    }
    _outputCleanupRequested = pendingOrphans;
  }

  Future<BackupRemoteOutput> _prepareExport(
    WorkspaceBackupChange c,
  ) => owner.exportLibrary(() async {
    if (c.action != WorkspaceBackupAction.export) throw const FormatException();
    final previous = await backups.remoteOutputReceipt(c.operationId);
    if (previous != null) {
      if (_remoteCommand(previous).digest != c.digest)
        throw const StorageFailure('operation_conflict');
      return previous;
    }
    if (!await backups.registerOwnerOperation(c.json)) {
      throw const WorkspaceFailure('not_submitted', '原备份未生成，请核对原操作后重新选择。');
    }
    // An artifact without a committed manifest was never offered to a client.
    // Reclaim it before producing another large snapshot, so failed attempts
    // cannot accumulate unbounded encrypted files during the grace period.
    _outputCleanupRequested = true;
    await _cleanupOutputs(forceOrphans: true);
    final id = _id();
    final folder = Directory('${directory.path}/out-$id');
    if (await FileSystemEntity.type(folder.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const StorageFailure('backup_staging_failed');
    }
    await folder.create();
    if ((await Process.run('/bin/chmod', ['700', folder.path])).exitCode != 0)
      throw const StorageFailure('backup_staging_failed');
    _outputCleanupRequested = true;
    // Linux uses the existing encrypted snapshot writer, never the Mac native
    // publication driver. Only the requesting device publishes its own file.
    await backups.exportTo(_artifactPath(id), stagingParent: folder.path);
    return backups.recordRemoteBackupPrepared(
      operationId: c.operationId,
      commandDigest: c.digest,
      expectedVersion: c.expectedVersion,
      resourceId: c.selection!.id,
      fileName: c.selection!.name,
      resourceVersion: c.selection!.version,
      artifactId: id,
      encryptedPath: _artifactPath(id),
    );
  });

  Future<Map<String, Object?>> _recoveryKey() => owner.exportLibrary(() async {
    final key = await backups.recoveryKey();
    if (key == null) throw const StorageFailure('backup_not_enabled');
    final bytes = utf8.encode('$key\n');
    return {
      'wireVersion': 1,
      'recoveryKey': key,
      'sha256': sha256.convert(bytes).toString(),
      'byteLength': bytes.length,
      'version': await backups.operationVersion(),
    };
  });

  Future<BackupRemoteOutput> _export(String id) async {
    final r = await backups.remoteOutputReceipt(id);
    if (r == null) throw const WorkspaceFailure('not_found', '原备份不存在。');
    _transfer(r); // Validate the complete command before any artifact is read.
    return r;
  }

  Future<Map<String, Object?>> _download(String id, Object? body) async {
    final r = await _export(id);
    if (r.phase != BackupRemoteOutputPhase.prepared)
      throw const StorageFailure('backup_transfer_finished');
    final v = backupEnvelope(body, ['offset', 'length']);
    final offset = backupInt(v['offset'], max: r.byteLength - 1);
    final length = backupInt(
      v['length'],
      min: 1,
      max: OwnerBackupRoutes.chunkBytes,
    );
    if (offset + length > r.byteLength) throw const FormatException();
    final path = _artifactPath(r.artifactId!);
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await File(path).length() != r.byteLength)
      throw const StorageFailure('backup_changed');
    final file = await File(path).open();
    try {
      await file.setPosition(offset);
      final bytes = await file.read(length);
      if (bytes.length != length) throw const StorageFailure('backup_changed');
      // The device verifies the whole manifest digest before publication.
      return {
        'wireVersion': 1,
        'offset': offset,
        'bytes': base64Encode(bytes),
        'byteLength': r.byteLength,
        'sha256': r.contentDigest,
      };
    } finally {
      await file.close();
    }
  }

  Future<WorkspaceBackupReceipt> _confirmOutput(Object? raw) =>
      owner.exportLibrary(() async {
        final v = backupEnvelope(raw, ['change', 'sha256']);
        final c = backupChangeFromJson(v['change']);
        final digest = backupHash(v['sha256']);
        late BackupRemoteOutput r;
        if (c.action == WorkspaceBackupAction.saveKey) {
          final old = await backups.ownerOperationIntent(c.operationId);
          if (old != null && old.digest != c.digest)
            throw const StorageFailure('operation_conflict');
          if (old != null &&
              !old.pending &&
              await backups.remoteOutputReceipt(c.operationId) == null) {
            throw const WorkspaceFailure(
              'not_submitted',
              '原登记已确认未提交，请重新操作；不会重新保存文件。',
            );
          }
          if (old == null) await backups.registerOwnerOperation(c.json);
          r = await backups.recordRemoteRecoveryKeySaved(
            operationId: c.operationId,
            commandDigest: c.digest,
            expectedVersion: c.expectedVersion,
            resourceId: c.selection!.id,
            fileName: c.selection!.name,
            resourceVersion: c.selection!.version,
            contentDigest: digest,
          );
        } else if (c.action == WorkspaceBackupAction.export) {
          final old = await _export(c.operationId);
          if (_remoteCommand(old).digest != c.digest)
            throw const StorageFailure('operation_conflict');
          r = await backups.finishRemoteBackupOutput(
            c.operationId,
            c.digest,
            digest,
            saved: true,
          );
        } else {
          throw const FormatException();
        }
        final result = _remoteReceipt(r);
        try {
          await backups.acknowledgeOwnerOperation(c.operationId, c.digest);
        } catch (_) {}
        _outputCleanupRequested = true;
        try {
          await _cleanupOutputs();
        } catch (_) {
          /* Cleanup never undoes a saved output. */
        }
        return result;
      });

  Future<void> _abandonOutput(Object? raw) => owner.exportLibrary(() async {
    final v = backupEnvelope(raw, ['change', 'sha256']);
    final c = backupChangeFromJson(v['change']);
    final digest = backupHash(v['sha256']);
    final r = await _export(c.operationId);
    if (_remoteCommand(r).digest != c.digest)
      throw const StorageFailure('operation_conflict');
    await backups.finishRemoteBackupOutput(
      c.operationId,
      c.digest,
      digest,
      saved: false,
    );
    await backups.acknowledgeOwnerOperation(c.operationId, c.digest);
    _outputCleanupRequested = true;
    await _cleanupOutputs();
  });

  Future<WorkspaceBackupReceipt> _change(WorkspaceBackupChange c) async {
    if (c.action == WorkspaceBackupAction.restore) return _restore(c);
    if (!const {
      WorkspaceBackupAction.enableKey,
      WorkspaceBackupAction.cleanup,
    }.contains(c.action)) {
      throw const FormatException('Output must be saved by the device first');
    }
    return owner.exportLibrary(() async {
      if (!await backups.registerOwnerOperation(c.json)) {
        return await _storedReceipt(c.operationId) ??
            (throw const WorkspaceFailure('not_submitted', '原操作未提交。'));
      }
      late WorkspaceBackupReceipt result;
      if (c.action == WorkspaceBackupAction.enableKey) {
        final r = await backups.enableWithReceipt(
          operationId: c.operationId,
          commandDigest: c.digest,
          expectedVersion: c.expectedVersion,
        );
        result = WorkspaceBackupReceipt(
          operationId: r.operationId,
          commandDigest: r.commandDigest,
          action: c.action,
          expectedVersion: r.expectedVersion,
          version: r.version,
        );
      } else {
        for (final id in _uploads.keys.toList()) {
          await _release(id);
        }
        _outputCleanupRequested = true;
        await _cleanupOutputs(forceOrphans: true);
        final r = await backups.finishOwnerCleanup(c.operationId);
        result = WorkspaceBackupReceipt(
          operationId: r.operationId,
          commandDigest: r.commandDigest,
          action: c.action,
          expectedVersion: r.expectedVersion,
          version: r.version,
        );
      }
      try {
        await backups.acknowledgeOwnerOperation(c.operationId, c.digest);
      } catch (_) {}
      return result;
    });
  }
}
