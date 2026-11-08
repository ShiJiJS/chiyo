import 'workspace_file_action_context.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import '../backups.dart';
import 'owner_workspace_files.dart';
import 'owner_workspace_information.dart';
import 'workspace_source.dart';

/// Trusted Owner adapter. Only this layer sees native output paths/bookmarks.
class WorkspaceFileActions {
  WorkspaceFileActions(this.context, this.outputs, this.picker, {this.opens});
  final WorkspaceFileActionContext context;
  final InformationFileOutputs outputs;
  final BackupFilePicker picker;
  final InformationFileOpens? opens;
  bool _disposed = false;
  void dispose() {
    _disposed = true;
  }

  /// Runtime maintenance uses only the private journal and recorded native
  /// capabilities. It can clean completed outputs while the server is offline;
  /// an uncertain publication retains its anchor and is never republished.
  Future<int> maintain() async {
    var failed = 0;
    for (final s in await outputs.pending(includeInvalidated: true)) {
      try {
        if (s.uncertain) continue;
        await _cleanup(s.operationId);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  void _current() {
    if (_disposed || !context.isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料库已关闭或更换，请重新打开文件。');
    }
  }

  WorkspaceFailure _failure(Object e) {
    if (e is WorkspaceFailure) return e;
    final code = e is StorageFailure
        ? e.code
        : e is core.AccessFailure
        ? e.status
        : '';
    return switch (code) {
      'operation_conflict' => const WorkspaceFailure(
        'operation_conflict',
        '原操作编号已用于其他内容。',
      ),
      'library_changed' || 'library_closed' => const WorkspaceFailure(
        'library_changed',
        '资料库已关闭或更换，请重新打开文件。',
      ),
      'backup_access_required' ||
      'file_access_required' => const WorkspaceFailure(
        'file_access_required',
        '需要重新选择原来另存的文件以核对结果，不会重写文件。',
      ),
      'attachment_integrity_failed' || 'attachment_missing' =>
        const WorkspaceFailure('attachment_missing', '文件原文缺失或校验失败，未另存。'),
      _ => const WorkspaceFailure('unknown_outcome', '暂时无法确认另存结果，请先核对原操作。'),
    };
  }

  WorkspaceFileOperationReceipt _receipt(InformationFileOutputStatus s) =>
      WorkspaceFileOperationReceipt(
        WorkspaceRecordRef(WorkspaceRecordKind.information, s.itemId),
        WorkspaceFileRef(
          s.reference.attachmentId,
          s.reference.attachmentVersion,
        ),
        actionCompleted: s.completed,
        cleanupPending: s.cleanupPending,
        commandDigest: s.commandDigest,
      );
  Future<T> _access<T>(
    String id,
    bool output,
    Future<T> Function() action,
  ) async {
    final args = await outputs.access(id);
    if (args['stagingBookmark']!.isEmpty) {
      return action(); // Non-native fixtures only.
    }
    final token = await picker.acquireAccess(args, needsOutput: output);
    try {
      return await action();
    } finally {
      await picker.releaseAccess(token);
    }
  }

  Future<void> _cleanup(
    String id, {
    BackupStaging? live,
    InformationFileOutputStatus? known,
  }) async {
    final s = known ?? await outputs.status(id);
    if (s == null || !s.cleanupPending) return;
    if (live != null) {
      await outputs.cleanup(
        id,
        releaseStaging: () => picker.releaseStaging(live),
      );
    } else {
      await _access(
        id,
        false,
        () async => outputs.cleanup(
          id,
          releaseStaging: () async =>
              picker.releaseRecordedStaging(await outputs.stagingDirectory(id)),
        ),
      );
    }
  }

  Future<InformationFileOutputStatus?> _reconcile(
    String id, {
    bool live = false,
  }) async {
    final s = await outputs.status(id);
    if (s == null) return null;
    final result = s.uncertain && !live
        ? await _access(id, true, () => outputs.reconcile(id))
        : await outputs.reconcile(id);
    return result;
  }

  Future<WorkspaceFileOperationReceipt?> receipt(String id) async {
    try {
      return await context.run(() async {
        _current();
        final s = await _reconcile(id);
        if (s == null) return null;
        try {
          await _cleanup(id);
        } catch (_) {
          /* Durable cleanup queue remains. */
        }
        return _receipt((await outputs.status(id))!);
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  Future<WorkspaceFileActionState> state(
    WorkspaceRecordRef record,
    String key,
  ) async {
    try {
      return await context.run(() async {
        _current();
        final all = (await outputs.pending())
            .where((s) => s.itemId == record.id && s.fieldKey == key)
            .toList();
        final pending = <InformationFileOutputStatus>[];
        for (final s in all) {
          if (s.phase == InformationFileOutputPhase.reserved ||
              s.phase == InformationFileOutputPhase.prepared) {
            await outputs.reconcile(s.operationId);
          } else if (s.uncertain) {
            pending.add(s);
          }
        }
        if (pending.length > 1) {
          throw const WorkspaceFailure('unknown_outcome', '有多项未确认另存，请先核对原操作。');
        }
        final p = pending.firstOrNull;
        return WorkspaceFileActionState(
          pending: p == null
              ? null
              : WorkspacePendingFileAction(
                  p.operationId,
                  p.commandDigest,
                  WorkspaceFileRef(
                    p.reference.attachmentId,
                    p.reference.attachmentVersion,
                  ),
                ),
          cleanupPending: (await outputs.pending(includeInvalidated: true))
              .where(
                (s) =>
                    s.itemId == record.id && s.fieldKey == key && !s.uncertain,
              )
              .length,
        );
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  Future<void> cleanup(WorkspaceRecordRef record, String key) async {
    try {
      await context.run(() async {
        _current();
        for (final s in await outputs.pending(includeInvalidated: true)) {
          if (s.itemId != record.id || s.fieldKey != key || s.uncertain) {
            continue;
          }
          await _cleanup(s.operationId, known: s);
        }
      });
    } catch (_) {
      throw const WorkspaceFailure(
        'cleanup_pending',
        '暂存尚未清理完成，已保存的文件不受影响，可稍后重试。',
      );
    }
  }

  Future<void> recoverAccess(String id) async {
    // Explicit Owner click only. No library lock is held while the panel opens.
    try {
      _current();
      final before = await outputs.status(id);
      if (before == null || !before.uncertain) return;
      final args = await outputs.access(id);
      final bookmark = await picker.reselectOutput(args['destination']!);
      if (bookmark == null) return;
      await context.run(() async {
        _current();
        final now = await outputs.status(id);
        if (now == null ||
            now.commandDigest != before.commandDigest ||
            !now.uncertain) {
          throw const StorageFailure('operation_conflict');
        }
        await outputs.recordOutputBookmark(id, bookmark);
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  Future<WorkspaceFileActionResult> save(
    WorkspaceRecordRef record,
    String key,
    int version,
    String id,
  ) async {
    final digest = workspaceFileActionDigest(
      record,
      key,
      version,
      WorkspaceFileAction.saveAs,
    );
    BackupStaging? staging;
    MacBackupStagingDirectory? root;
    var registered = false;
    try {
      _current();
      final old = await outputs.status(id);
      if (old != null) {
        if (old.commandDigest != digest) {
          throw const StorageFailure('operation_conflict');
        }
        final current = (await context.history(record, key)).current.ref;
        if (current.id != old.reference.attachmentId ||
            current.version != version) {
          throw const WorkspaceFailure('conflict', '文件绑定已变化，请核对原操作结果。');
        }
        final r = await receipt(id);
        return WorkspaceFileActionResult(
          completed: r!.actionCompleted == true,
          filename: old.fileName,
          cleanupPending: (await outputs.status(id))!.cleanupPending,
        );
      }
      // A previous process's uncertain write blocks a new write to this field.
      final state = await this.state(record, key);
      if (state.pending != null) {
        throw const WorkspaceFailure('previous_pending', '原另存操作尚未确认，请先核对。');
      }
      final history = await context.history(record, key);
      if (history.current.ref.version != version) {
        throw const WorkspaceFailure('conflict', '文件版本已变化，请重新核对。');
      }
      final detail = await context.detail(record);
      final fieldId = detail.fieldIds[key];
      final path = await picker.ownerFileOutput(history.current.filename);
      if (path == null) {
        return WorkspaceFileActionResult(
          completed: false,
          filename: history.current.filename,
        );
      }
      _current();
      final ref = core.InformationAttachmentRef(
        history.current.ref.id,
        version,
      );
      final body = await context.original(record, key, ref);
      return await context.run(() async {
        _current();
        await context.assertCurrent(record, key, fieldId, ref);
        final oldSave = (await outputs.pending()).any(
          (s) => s.itemId == record.id && s.fieldKey == key && s.uncertain,
        );
        final oldOpen = (await opens?.copies() ?? <InformationFileOpenStatus>[])
            .any(
              (s) =>
                  s.itemId == record.id &&
                  s.fieldKey == key &&
                  !s.closed &&
                  s.uncertain,
            );
        if (oldSave || oldOpen) {
          throw const WorkspaceFailure('previous_pending', '原文件操作尚未确认，请先核对。');
        }
        staging = await picker.prepareStaging(path);
        if (staging == null) {
          throw const WorkspaceFailure('unsupported', '当前系统不能创建安全的另存暂存。');
        }
        root = MacBackupPublicationFiles.captureStaging(staging!.directory);
        _current();
        await outputs.reserve(
          operationId: id,
          commandDigest: digest,
          itemId: record.id,
          fieldKey: key,
          reference: ref,
          root: root!,
          destination: path,
          length: body.file.byteLength,
          contentDigest: body.sha256,
          stagingBookmark: staging!.stagingBookmark ?? '',
        );
        registered = true;
        _current();
        await outputs.prepare(id, body.bytes);
        _current();
        final done = await outputs.publish(
          id,
          afterPublication: staging!.stagingBookmark == null
              ? null
              : () async {
                  await outputs.recordOutputBookmark(
                    id,
                    await picker.outputBookmark(staging!),
                  );
                },
        );
        try {
          await _cleanup(id, live: staging);
        } catch (_) {
          /* Independent durable cleanup queue. */
        }
        if (!done.completed) {
          throw const WorkspaceFailure(
            'not_saved',
            '未另存文件；所选名称可能已存在，请核对后选择新的名称。',
          );
        }
        return WorkspaceFileActionResult(
          completed: true,
          filename: done.fileName,
          cleanupPending: (await outputs.status(id))!.cleanupPending,
        );
      });
    } catch (e) {
      if (registered) {
        try {
          final done = await context.run(() async {
            _current();
            final result = await _reconcile(id, live: true);
            if (result != null && !result.uncertain) {
              try {
                await _cleanup(id, live: staging);
              } catch (_) {
                /* Remains queued. */
              }
            }
            return result;
          });
          if (done?.completed == true) {
            return WorkspaceFileActionResult(
              completed: true,
              filename: done!.fileName,
              cleanupPending: (await outputs.status(id))!.cleanupPending,
            );
          }
          if (done != null && !done.uncertain) {
            throw const WorkspaceFailure('not_saved', '另存未完成，原文件未覆盖，请核对后重试。');
          }
        } on WorkspaceFailure catch (failure) {
          if (failure.code == 'not_saved') rethrow;
        } catch (_) {
          /* Preserve original unknown outcome. */
        }
      } else if (staging != null) {
        // Before registration no material has been written. Only this exact
        // empty native allocation may be released; no recursive cleanup.
        try {
          if (root != null) MacBackupPublicationFiles.cleanupStaging(root!);
          await picker.releaseStaging(staging!);
        } catch (_) {
          /* Native allocation contains no plaintext material. */
        }
      }
      throw _failure(e);
    }
  }
}

/// Compatibility composition for the local owner runtime.
class OwnerWorkspaceFileActions extends WorkspaceFileActions {
  OwnerWorkspaceFileActions(
    core.OwnerAccess owner,
    OwnerWorkspaceInformation information,
    OwnerWorkspaceFiles files,
    InformationFileOutputs outputs,
    BackupFilePicker picker, {
    super.opens,
  }) : super(
         OwnerFileActionContext(owner, information, files),
         outputs,
         picker,
       );
}
