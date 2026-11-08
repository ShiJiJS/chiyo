import 'workspace_file_action_context.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'owner_workspace_files.dart';
import 'owner_workspace_information.dart';
import 'workspace_source.dart';

class WorkspaceFileOpens {
  WorkspaceFileOpens(this.context, this.opens, this.dispatcher, {this.outputs});
  final WorkspaceFileActionContext context;
  final InformationFileOpens opens;
  final OwnerFileOpenDispatcher dispatcher;
  final InformationFileOutputs? outputs;
  bool _disposed = false;
  void dispose() {
    _disposed = true;
  }

  void _current() {
    if (_disposed || !context.isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料窗口已关闭或资料库已更换。');
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
        '此编号已用于其他操作。',
      ),
      'library_changed' || 'library_closed' => const WorkspaceFailure(
        'library_changed',
        '资料库已关闭或更换，请重新打开资料。',
      ),
      'attachment_missing' ||
      'attachment_integrity_failed' ||
      'file_read_failed' => const WorkspaceFailure(
        'attachment_missing',
        '文件原文缺失或校验失败，未交给本机程序。',
      ),
      'service_unavailable' => const WorkspaceFailure(
        'unavailable',
        '文件服务已关闭，请重新打开应用。',
      ),
      'file_open_capacity' => const WorkspaceFailure(
        'capacity',
        '临时副本已达到容量上限，请先结束使用并清理一些副本。',
      ),
      _ => const WorkspaceFailure(
        'unknown_outcome',
        '暂时无法确认本机程序是否收到打开请求，请先核对原操作。',
      ),
    };
  }

  WorkspaceFileOperationReceipt _receipt(InformationFileOpenStatus s) =>
      WorkspaceFileOperationReceipt(
        WorkspaceRecordRef(WorkspaceRecordKind.information, s.itemId),
        WorkspaceFileRef(
          s.reference.attachmentId,
          s.reference.attachmentVersion,
        ),
        actionCompleted: s.completed,
        openCopyHeld: !s.closed && s.cleanupPending,
        commandDigest: s.commandDigest,
        cleanupPending: s.closed && s.cleanupPending,
      );
  Future<WorkspaceFileOperationReceipt?> receipt(String id) async {
    try {
      return await context.run(() async {
        _current();
        final s = await opens.reconcile(id, dispatcher);
        return s == null ? null : _receipt(s);
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
        final all = (await opens.copies(
          includeInvalidated: true,
        )).where((s) => s.itemId == record.id && s.fieldKey == key).toList();
        final pending = all
            .where((s) => !s.invalidated && !s.closed && s.uncertain)
            .toList();
        if (pending.length > 1) {
          throw const WorkspaceFailure(
            'unknown_outcome',
            '多项打开结果尚未确认，请先结束使用并清理临时副本。',
          );
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
                  action: WorkspaceFileAction.open,
                ),
          openCopies: all.where((s) => !s.closed && !s.invalidated).length,
          openCleanupPending: all
              .where((s) => s.closed || s.invalidated)
              .length,
        );
      });
    } catch (e) {
      throw _failure(e);
    }
  }

  Future<void> finish(String id) async {
    try {
      await context.run(() async {
        _current();
        await opens.close(id);
      });
    } catch (_) {
      throw const WorkspaceFailure(
        'cleanup_pending',
        '临时副本尚未清理完成，请重试；打开结果不会因此改成成功。',
      );
    }
  }

  Future<void> closeCopies(WorkspaceRecordRef record, String key) async {
    try {
      await context.run(() async {
        _current();
        for (final s in await opens.copies(includeInvalidated: true)) {
          if (s.itemId == record.id && s.fieldKey == key) {
            await opens.close(s.operationId);
          }
        }
      });
    } catch (_) {
      throw const WorkspaceFailure('cleanup_pending', '临时副本尚未清理完成，请稍后重试。');
    }
  }

  String _safeName(String media) =>
      'attachment.${switch (media) {
        'application/pdf' => 'pdf',
        'text/plain' => 'txt',
        'image/png' => 'png',
        'image/jpeg' => 'jpg',
        'image/webp' => 'webp',
        'application/msword' => 'doc',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
        _ => throw const WorkspaceFailure('unsupported', '此格式尚不支持交给本机程序打开，可以另存原文。'),
      }}';
  Future<WorkspaceFileActionResult> open(
    WorkspaceRecordRef record,
    String key,
    int version,
    String id,
  ) async {
    final digest = workspaceFileActionDigest(
      record,
      key,
      version,
      WorkspaceFileAction.open,
    );
    var registered = false;
    try {
      _current();
      final old = await opens.status(id);
      final history = await context.history(record, key);
      if (history.current.ref.version != version ||
          old != null &&
              (old.reference.attachmentId != history.current.ref.id ||
                  old.commandDigest != digest)) {
        throw const WorkspaceFailure('conflict', '文件绑定或原命令已变化，请重新核对。');
      }
      if (old != null) {
        final r = await receipt(id);
        if (r!.actionCompleted != true) {
          throw const WorkspaceFailure('not_opened', '系统未接收此次打开请求。');
        }
        return WorkspaceFileActionResult(
          completed: true,
          filename: old.fileName,
        );
      }
      if ((await state(record, key)).pending != null) {
        throw const WorkspaceFailure('previous_pending', '原打开操作尚未确认，请先核对。');
      }
      final name = _safeName(history.current.mediaType);
      final fieldId = (await context.detail(record)).fieldIds[key];
      final ref = core.InformationAttachmentRef(
        history.current.ref.id,
        version,
      );
      final body = await context.original(record, key, ref);
      return await context.run(() async {
        _current();
        await context.assertCurrent(record, key, fieldId, ref);
        final oldOpen = (await opens.copies()).any(
          (s) =>
              s.itemId == record.id &&
              s.fieldKey == key &&
              !s.closed &&
              s.uncertain,
        );
        final oldSave =
            (await outputs?.pending() ?? <InformationFileOutputStatus>[]).any(
              (s) => s.itemId == record.id && s.fieldKey == key && s.uncertain,
            );
        if (oldOpen || oldSave) {
          throw const WorkspaceFailure('previous_pending', '原文件操作尚未确认，请先核对。');
        }
        await opens.prepare(
          operationId: id,
          commandDigest: digest,
          itemId: record.id,
          fieldKey: key,
          reference: ref,
          fileName: body.file.filename,
          safeName: name,
          bytes: body.bytes,
          sha256: body.sha256,
        );
        registered = true;
        _current();
        final s = await opens.open(id, dispatcher);
        if (!s.completed) {
          throw const WorkspaceFailure('not_opened', '系统未能接收此文件，请另存后打开。');
        }
        return WorkspaceFileActionResult(completed: true, filename: s.fileName);
      });
    } catch (e) {
      if (registered && (_disposed || !context.isCurrent)) {
        try {
          await context.run(() => opens.close(id));
        } catch (_) {
          /* Runtime still owns durable cleanup. */
        }
      }
      if (registered) {
        try {
          final s = await context.run(() async {
            _current();
            return opens.reconcile(id, dispatcher);
          });
          if (s?.completed == true) {
            return WorkspaceFileActionResult(
              completed: true,
              filename: s!.fileName,
            );
          }
          if (s != null && !s.uncertain) {
            throw const WorkspaceFailure('not_opened', '系统未接收此次打开请求。');
          }
        } on WorkspaceFailure catch (f) {
          if (f.code == 'not_opened') rethrow;
        } catch (_) {
          /* Original intent remains. */
        }
      }
      throw _failure(e);
    }
  }
}

/// Compatibility composition for the local owner runtime.
class OwnerWorkspaceFileOpens extends WorkspaceFileOpens {
  OwnerWorkspaceFileOpens(
    core.OwnerAccess owner,
    OwnerWorkspaceInformation information,
    OwnerWorkspaceFiles files,
    InformationFileOpens opens,
    OwnerFileOpenDispatcher dispatcher, {
    super.outputs,
  }) : super(
         OwnerFileActionContext(owner, information, files),
         opens,
         dispatcher,
       );
}
