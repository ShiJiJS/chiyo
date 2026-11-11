import 'dart:convert';
import 'dart:math';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import '../backups.dart';
import 'owner_workspace_backup_files.dart';
import 'workspace_source.dart';

/// Production Owner adapter. Pages see opaque selections/receipts only. All
/// storage and native work is serialized behind the existing Owner barrier.
class OwnerWorkspaceBackups
    implements WorkspaceBackupSource, WorkspaceBackupAccessRecovery {
  OwnerWorkspaceBackups({
    required this.owner,
    required this.backups,
    required this.files,
    this.picker = const NativeBackupFilePicker(),
    this.onRestored,
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final InformationBackups backups;
  final OwnerWorkspaceBackupFiles files;
  final BackupFilePicker picker;
  final void Function()? onRestored;
  final core.OwnerLibraryScope _scope;
  final _previews =
      <String, ({WorkspaceBackupPreview page, BackupRestorePreview storage})>{};
  bool _closed = false;

  void _current() {
    if (_closed) throw const WorkspaceFailure('unavailable', '此备份窗口已关闭。');
    if (!_scope.isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料库已更换，请重新打开备份。');
    }
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '信息库暂时不可用。');
    }
  }

  WorkspaceFailure _failure(Object e, {bool uncertain = false}) {
    if (e is WorkspaceFailure) return e;
    final code = e is StorageFailure
        ? e.code
        : e is core.AccessFailure
        ? e.status
        : '';
    return switch (code) {
      'library_changed' => const WorkspaceFailure(
        'library_changed',
        '资料库已更换，请重新打开备份。',
      ),
      'operation_conflict' || 'backup_version_conflict' =>
        const WorkspaceFailure('conflict', '备份状态或原操作已变化，请刷新后重新操作。'),
      'recipient_not_empty' => const WorkspaceFailure(
        'recipient_not_empty',
        '当前信息库已有资料或历史，不能覆盖或合并恢复。',
      ),
      'invalid_recovery_key' => const WorkspaceFailure(
        'invalid_recovery_key',
        '恢复密钥文件格式不正确，请重新选择。',
      ),
      'invalid_backup' => const WorkspaceFailure(
        'invalid_backup',
        '密钥不匹配、备份损坏或内容无效。',
      ),
      'unsupported_backup' => const WorkspaceFailure(
        'unsupported_backup',
        '此备份格式暂不支持。',
      ),
      'backup_changed' || 'backup_preview_expired' => const WorkspaceFailure(
        'backup_changed',
        '文件或检查状态已变化，请重新选择并检查。',
      ),
      'output_exists' || 'backup_not_published' => const WorkspaceFailure(
        'not_submitted',
        '文件未保存，请选择新的文件名；已有文件不会覆盖。',
      ),
      'recovery_key_not_saved' => const WorkspaceFailure(
        'key_not_saved',
        '请先独立保存恢复密钥文件。',
      ),
      'backup_cleanup_pending' => const WorkspaceFailure(
        'cleanup_pending',
        '暂存清理尚未完成，可以重试清理剩余项。',
      ),
      'backup_access_required' => const WorkspaceFailure(
        'backup_access_required',
        '原文件访问无法恢复，请重新选择上次保存的原文件后核对；不会再次导出。',
      ),
      'backup_outcome_unknown' || 'invalid_backup_operation_receipt' =>
        const WorkspaceFailure('unknown_outcome', '原操作结果尚未确认，请核对原操作。'),
      _ => WorkspaceFailure(
        uncertain ? 'unknown_outcome' : 'unavailable',
        uncertain ? '原操作结果尚未确认，请核对原操作。' : '备份操作未完成，请检查文件选择与存储状态。',
      ),
    };
  }

  WorkspaceBackupCounts _counts(Map<String, int> values) =>
      WorkspaceBackupCounts({
        for (final entry in values.entries)
          WorkspaceBackupCategory.values.byName(entry.key): entry.value,
      });
  WorkspaceBackupChange _command(BackupOwnerIntent intent) {
    final c = intent.command, selection = c['selection'] as Map?;
    return WorkspaceBackupChange(
      operationId: intent.operationId,
      action: WorkspaceBackupAction.values.byName(intent.action),
      expectedVersion: intent.expectedVersion,
      selection: selection == null
          ? null
          : WorkspaceBackupResource(
              id: selection['id'] as String,
              name: selection['name'] as String,
              kind: WorkspaceBackupPick.values.byName(
                selection['kind'] as String,
              ),
              version: selection['version'] as int,
            ),
      previewToken: c['previewToken'] as String?,
    );
  }

  @override
  Future<WorkspaceBackupStatus> status() async {
    _current();
    try {
      return await owner.exportLibrary(() async {
        _current();
        final pending = await backups.pendingOwnerOperations();
        final empty = await backups.recipientEmpty();
        final latest = await backups.latestExportOperation();
        return WorkspaceBackupStatus(
          version: await backups.operationVersion(),
          keyCreated: await backups.recoveryKey() != null,
          keySaved: await backups.recoveryKeySaved(),
          recipientEmpty: empty,
          blockers: empty ? const [] : const ['资料、设置以外的记录或历史'],
          cleanupCount: await backups.pendingOutputCleanupCount(),
          latestArchiveAt: latest?.completedAt,
          latestArchiveLocation: latest?.destination,
          latestArchive: latest == null
              ? null
              : _outputReceipt(latest).resource,
          pending: pending.isEmpty
              ? null
              : WorkspaceBackupPending(
                  _command(pending.single),
                  restoreCounts: pending.single.restoreCounts == null
                      ? null
                      : _counts(pending.single.restoreCounts!),
                ),
        );
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  @override
  Future<String> revealRecoveryKey() async {
    _current();
    try {
      return await owner.exportLibrary(() async {
        _current();
        return await backups.recoveryKey() ??
            (throw const StorageFailure('backup_not_enabled'));
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  @override
  Future<WorkspaceBackupPreview> inspect(
    WorkspaceBackupResource archive,
    WorkspaceBackupResource key,
  ) async {
    _current();
    try {
      return await owner.exportLibrary(() async {
        _current();
        if ((await backups.pendingOwnerOperations()).isNotEmpty) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        final archivePath = files.pathFor(
          archive,
          kind: WorkspaceBackupPick.archiveInput,
        );
        final keyPath = files.pathFor(key, kind: WorkspaceBackupPick.keyInput);
        final recovery = await backups.readRecoveryKeyFrom(keyPath);
        final checked = await backups.inspectRestore(
          path: archivePath,
          recoveryKey: recovery,
          archiveId: archive.id,
          archiveVersion: archive.version,
        );
        try {
          _current();
          files.pathFor(archive, kind: WorkspaceBackupPick.archiveInput);
          files.pathFor(key, kind: WorkspaceBackupPick.keyInput);
          final random = Random.secure();
          final token = List.generate(
            32,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          final page = WorkspaceBackupPreview(
            token: token,
            archive: archive,
            key: key,
            counts: _counts(checked.counts),
            createdAt: checked.createdAt,
            formatLabel: '加密备份 · 格式 ${checked.formatVersion}',
          );
          _previews[token] = (page: page, storage: checked);
          return page;
        } catch (_) {
          checked.release();
          rethrow;
        }
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  @override
  Future<void> releasePreview(String token) async {
    _previews.remove(token)?.storage.release();
  }

  WorkspaceBackupReceipt _keyReceipt(BackupKeyOperationReceipt r) =>
      WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: WorkspaceBackupAction.enableKey,
        expectedVersion: r.expectedVersion,
        version: r.version,
      );
  WorkspaceBackupReceipt _outputReceipt(BackupOutputReceipt r) =>
      WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: r.action == BackupOutputAction.export
            ? WorkspaceBackupAction.export
            : WorkspaceBackupAction.saveKey,
        expectedVersion: r.expectedVersion,
        version: r.version,
        resource: WorkspaceBackupResource(
          id: 'output_${r.operationId}',
          name: r.fileName,
          kind: r.action == BackupOutputAction.export
              ? WorkspaceBackupPick.archiveInput
              : WorkspaceBackupPick.keyInput,
        ),
        counts: r.action == BackupOutputAction.export
            ? _counts(r.counts)
            : null,
      );
  WorkspaceBackupReceipt _restoreReceipt(BackupRestoreReceipt r) =>
      WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: WorkspaceBackupAction.restore,
        expectedVersion: r.expectedVersion,
        version: r.version,
        resource: WorkspaceBackupResource(
          id: r.archiveId,
          name: r.fileName,
          kind: WorkspaceBackupPick.archiveInput,
          version: r.archiveVersion,
        ),
        counts: _counts(r.counts),
      );
  WorkspaceBackupReceipt _cleanupReceipt(BackupCleanupReceipt r) =>
      WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: WorkspaceBackupAction.cleanup,
        expectedVersion: r.expectedVersion,
        version: r.version,
      );
  void _matches(
    WorkspaceBackupReceipt result,
    WorkspaceBackupChange c,
    Map<String, int>? counts,
  ) {
    if (!result.matches(c) ||
        c.action == WorkspaceBackupAction.restore &&
            (counts == null ||
                result.counts == null ||
                !result.counts!.same(_counts(counts)))) {
      throw const StorageFailure('backup_outcome_unknown');
    }
  }

  Future<WorkspaceBackupReceipt?> _lookup(String id) async {
    final action = await backups.backupOperationAction(id);
    switch (action) {
      case null:
        return null;
      case 'enableKey':
        return _keyReceipt((await backups.recoveryKeyOperationReceipt(id))!);
      case 'saveKey':
      case 'export':
        final result = await _withAccess(
          id,
          needsOutput: true,
          activateAccess:
              await backups.outputOperationPhase(id) ==
              BackupOutputPhase.publishing,
          action: () => backups.reconcileOutputOperation(id),
        );
        return result == null ? null : _outputReceipt(result);
      case 'restore':
        return _restoreReceipt((await backups.restoreOperationReceipt(id))!);
      case 'cleanup':
        return _cleanupReceipt((await backups.cleanupOperationReceipt(id))!);
      default:
        throw const StorageFailure('operation_conflict');
    }
  }

  Future<void> _ack(BackupOwnerIntent intent) =>
      backups.acknowledgeOwnerOperation(intent.operationId, intent.digest);
  Future<WorkspaceBackupReceipt?> _reconcile(String id) async {
    final intent = await backups.ownerOperationIntent(id);
    var result = await _lookup(id);
    if (intent != null) {
      if (result == null && intent.action == 'cleanup' && intent.pending) {
        if (await backups.pendingOutputCleanupCount() != 0) {
          await _ack(intent);
          throw const WorkspaceFailure(
            'cleanup_pending',
            '原清理尚未完成，可重试清理剩余暂存；已保存的文件不受影响。',
          );
        }
        result = _cleanupReceipt(await backups.finishOwnerCleanup(id));
      }
      if (result != null) {
        _matches(result, _command(intent), intent.restoreCounts);
      }
      await _ack(intent);
    }
    return result;
  }

  @override
  Future<WorkspaceBackupReceipt?> receipt(String operationId) async {
    _current();
    try {
      return await owner.exportLibrary(() async {
        _current();
        return _reconcile(operationId);
      });
    } catch (e) {
      throw _failure(e, uncertain: true);
    }
  }

  Future<void> _cleanupOne(String id) async {
    final directory = await backups.outputStagingDirectory(id);
    if (directory == null) {
      await backups.cleanupOutputOperation(id);
      return;
    }
    await _withAccess(
      id,
      needsOutput: false,
      action: () => backups.cleanupRegisteredOutputStaging(
        id,
        releaseNative: () =>
            picker.releaseRecordedStaging(directory.toPrivateJson()),
      ),
    );
  }

  Future<T> _withAccess<T>(
    String id, {
    required bool needsOutput,
    bool activateAccess = true,
    required Future<T> Function() action,
  }) async {
    final access = activateAccess
        ? await backups.outputStagingAccess(id)
        : null;
    if (access == null) {
      return action(); // Older journals and non-native fixtures.
    }
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

  @override
  Future<bool> requestRecoveryAccess(String operationId) async {
    _current();
    try {
      // The file panel must not hold the library lock. Revalidate the exact
      // intent and generation after it returns, before storing any capability.
      final before = await owner.exportLibrary(() async {
        _current();
        final intent = await backups.ownerOperationIntent(operationId);
        final access = await backups.outputStagingAccess(operationId);
        if (intent == null ||
            !intent.pending ||
            access == null ||
            !{'saveKey', 'export'}.contains(intent.action) ||
            await backups.outputOperationPhase(operationId) !=
                BackupOutputPhase.publishing) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        return (intent: intent, access: access);
      });
      final bookmark = await picker.reselectOutput(before.access.destination);
      if (bookmark == null) return false;
      return await owner.exportLibrary(() async {
        _current();
        final intent = await backups.ownerOperationIntent(operationId);
        if (intent == null ||
            !intent.pending ||
            intent.digest != before.intent.digest) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        await backups.recordOutputBookmark(operationId, bookmark);
        return true;
      });
    } catch (e) {
      throw _failure(e, uncertain: true);
    }
  }

  Future<void> _cleanupAll() async {
    final ids = {
      ...await backups.pendingOutputStaging(),
      ...await backups.pendingOutputOperationIds(),
    };
    for (final id in ids) {
      await _cleanupOne(id);
    }
  }

  Future<WorkspaceBackupReceipt> _produce(WorkspaceBackupChange c) async {
    final kind = c.action == WorkspaceBackupAction.saveKey
        ? WorkspaceBackupPick.keyOutput
        : WorkspaceBackupPick.archiveOutput;
    final path = files.pathFor(c.selection!, kind: kind);
    BackupStaging? staging;
    var registered = false;
    try {
      staging = await picker.prepareStaging(path);
      if (staging == null) throw const StorageFailure('backup_staging_failed');
      _current();
      files.pathFor(c.selection!, kind: kind);
      await backups.registerOutputStaging(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: c.expectedVersion,
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
        final key = await backups.recoveryKey();
        if (key == null) throw const StorageFailure('backup_not_enabled');
        MacBackupPublicationFiles.writeRecoveryKey(
          prepared,
          utf8.encode('$key\n'),
        );
      } else {
        await backups.exportTo(
          prepared,
          stagingParent: staging.directory,
          onStagingCreated: (child) =>
              backups.registerOutputStagingChild(c.operationId, child),
        );
      }
      _current();
      files.pathFor(c.selection!, kind: kind);
      final publication = MacBackupPublicationFiles.prepare(prepared, path);
      await backups.prepareOutputOperation(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: c.expectedVersion,
        action: c.action == WorkspaceBackupAction.saveKey
            ? BackupOutputAction.saveKey
            : BackupOutputAction.export,
        publication: publication,
      );
      return _outputReceipt(
        await backups.publishOutputOperation(
          c.operationId,
          afterPublication: staging.stagingBookmark == null
              ? null
              : () async {
                  final bookmark = await picker.outputBookmark(staging!);
                  await backups.recordOutputBookmark(c.operationId, bookmark);
                },
        ),
      );
    } finally {
      // Success and cleanup are independent. The durable queue retains any
      // failed cleanup or unknown publication for explicit later reconciliation.
      try {
        if (registered) {
          await _cleanupOne(c.operationId);
        } else if (staging != null) {
          await picker.releaseStaging(staging);
        }
      } catch (_) {
        /* Never turn a committed output into a failed save. */
      }
    }
  }

  Future<WorkspaceBackupReceipt> _restore(WorkspaceBackupChange c) async {
    final raw = await owner.restoreLibraryOnce<BackupRestoreReceipt>(
      previous: () async {
        _current();
        final previous = await backups.ownerOperationIntent(c.operationId);
        if (previous != null) {
          if (previous.digest != c.digest) {
            throw const StorageFailure('operation_conflict');
          }
          final receipt = await backups.restoreOperationReceipt(c.operationId);
          if (receipt == null) {
            throw const WorkspaceFailure(
              'not_submitted',
              '原恢复未提交，请重新选择并检查后操作。',
            );
          }
          _matches(_restoreReceipt(receipt), c, previous.restoreCounts);
          return receipt;
        }
        final p = _previews[c.previewToken];
        if (p == null ||
            c.selection == null ||
            !p.page.archive.same(c.selection!)) {
          throw const StorageFailure('backup_preview_expired');
        }
        files.pathFor(p.page.archive, kind: WorkspaceBackupPick.archiveInput);
        files.pathFor(p.page.key, kind: WorkspaceBackupPick.keyInput);
        if (!await backups.registerOwnerOperation(
          c.json,
          restoreCounts: p.storage.counts,
        )) {
          throw const StorageFailure('operation_conflict');
        }
        return null;
      },
      restore: () => backups.restoreWithReceipt(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: c.expectedVersion,
        preview: _previews[c.previewToken]!.storage,
      ),
    );
    // No fallible work is inserted between the storage commit and Owner runtime
    // invalidation. Acknowledgement may remain pending but restore stays success.
    try {
      await backups.acknowledgeOwnerOperation(c.operationId, c.digest);
    } catch (_) {}
    _previews.remove(c.previewToken)?.storage.release();
    if (!_scope.isCurrent) onRestored?.call();
    return _restoreReceipt(raw);
  }

  @override
  Future<WorkspaceBackupReceipt> change(WorkspaceBackupChange c) async {
    _current();
    try {
      if (c.action == WorkspaceBackupAction.restore) return await _restore(c);
      return await owner.exportLibrary(() async {
        _current();
        final created = await backups.registerOwnerOperation(c.json);
        if (!created) {
          final old = await backups.ownerOperationIntent(c.operationId);
          if (old?.digest != c.digest) {
            throw const StorageFailure('operation_conflict');
          }
          final previous = await _reconcile(c.operationId);
          if (previous == null) {
            throw const WorkspaceFailure('not_submitted', '原操作未提交，请重新选择后操作。');
          }
          return previous;
        }
        final result = switch (c.action) {
          WorkspaceBackupAction.enableKey => _keyReceipt(
            await backups.enableWithReceipt(
              operationId: c.operationId,
              commandDigest: c.digest,
              expectedVersion: c.expectedVersion,
            ),
          ),
          WorkspaceBackupAction.saveKey ||
          WorkspaceBackupAction.export => await _produce(c),
          WorkspaceBackupAction.cleanup => await (() async {
            await _cleanupAll();
            return _cleanupReceipt(
              await backups.finishOwnerCleanup(c.operationId),
            );
          })(),
          WorkspaceBackupAction.restore => throw StateError(
            'restore uses its own barrier',
          ),
        };
        _matches(result, c, null);
        try {
          await backups.acknowledgeOwnerOperation(c.operationId, c.digest);
        } catch (_) {}
        return result;
      });
    } catch (e) {
      // Confirm the exact original result before returning any definite error.
      // A failed lookup remains unknown and the persisted intent stays pending.
      if (!_scope.isCurrent || _closed) throw _failure(e, uncertain: true);
      try {
        final recovered = await owner.exportLibrary(() async {
          final intent = await backups.ownerOperationIntent(c.operationId);
          if (intent == null) return null;
          if (intent.digest != c.digest) {
            throw const StorageFailure('operation_conflict');
          }
          return _reconcile(c.operationId);
        });
        if (recovered != null) return recovered;
      } catch (check) {
        if (check is StorageFailure && check.code == 'backup_access_required') {
          throw _failure(check, uncertain: true);
        }
        if (check is WorkspaceFailure && check.code == 'cleanup_pending') {
          rethrow;
        }
        if (check is StorageFailure && check.code == 'operation_conflict') {
          throw _failure(check);
        }
        throw const WorkspaceFailure('unknown_outcome', '原操作结果尚未确认，请核对原操作。');
      }
      throw _failure(e);
    }
  }

  void dispose() {
    _closed = true;
    for (final p in _previews.values) {
      p.storage.release();
    }
    _previews.clear();
    files.dispose();
  }
}
