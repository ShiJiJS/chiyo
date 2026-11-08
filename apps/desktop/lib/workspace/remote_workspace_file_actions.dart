import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/file_transport.dart';
import '../backups.dart';
import 'owner_file_open_dispatcher.dart';
import 'owner_workspace_file_actions.dart';
import 'owner_workspace_file_opens.dart';
import 'remote_workspace_files.dart';
import 'workspace_file_action_context.dart';
import 'workspace_source.dart';

/// Only native action receipts and cleanup identities persist on this device.
/// File bytes are fetched from the authenticated host and verified before the
/// existing publication/open coordinators create any usable local copy.
class RemoteWorkspaceFileActions {
  RemoteWorkspaceFileActions(
    this.client,
    this.files,
    this.readDetail, {
    required this.directory,
    this.picker = const NativeBackupFilePicker(),
    this.dispatcher = const NativeOwnerFileOpenDispatcher(),
  });
  final OwnerClient client;
  final RemoteWorkspaceFiles files;
  final Future<WorkspaceDetail> Function(WorkspaceRecordRef) readDetail;
  final String? directory;
  final BackupFilePicker picker;
  final OwnerFileOpenDispatcher dispatcher;
  Future<_DeviceActions>? _opening;
  bool _closed = false;

  Future<_DeviceActions> _open() async {
    final path = directory;
    if (_closed || path == null) {
      throw const WorkspaceFailure('unavailable', '本机文件操作尚未就绪，请重新连接。');
    }
    final scope = sha256.convert(utf8.encode(client.serverId)).toString();
    final store = await DeviceFileOperations.open(
      '$path/$scope',
      serverId: client.serverId,
    );
    try {
      if (_closed) throw const WorkspaceFailure('library_changed', '连接已关闭。');
      final context = _RemoteFileContext(client, files, readDetail);
      final saved = WorkspaceFileActions(
        context,
        store.fileOutputs,
        picker,
        opens: store.fileOpens,
      );
      final opened = WorkspaceFileOpens(
        context,
        store.fileOpens,
        dispatcher,
        outputs: store.fileOutputs,
      );
      await store.fileOpens.maintain(closePrevious: true);
      await saved.maintain();
      return _DeviceActions(store, context, saved, opened);
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  Future<_DeviceActions> _get() async {
    if (_closed) throw const WorkspaceFailure('library_changed', '连接已关闭。');
    final pending = _opening ??= _open();
    try {
      return await pending;
    } catch (_) {
      if (identical(_opening, pending)) _opening = null;
      rethrow;
    }
  }

  Future<T> _run<T>(Future<T> Function(_DeviceActions) f) async {
    try {
      return await f(await _get());
    } on StorageFailure catch (e) {
      throw WorkspaceFailure(e.code, '本机文件操作记录暂时无法读取，请稍后重试；不会重复写入或打开文件。');
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, '暂时无法连接资料服务器，请检查连接后重试。');
    }
  }

  Future<WorkspaceFileOperationReceipt?> receipt(String id) => _run((d) async {
    final saved = await d.saved.receipt(id),
        opened = await d.opened.receipt(id);
    if (saved != null && opened != null) {
      throw const WorkspaceFailure('unknown_outcome', '操作编号对应多种结果，无法确认。');
    }
    return opened ?? saved;
  });

  Future<WorkspaceFileActionState> state(
    WorkspaceRecordRef record,
    String key,
  ) => _run((d) async {
    final saved = await d.saved.state(record, key),
        opened = await d.opened.state(record, key);
    if (saved.pending != null && opened.pending != null) {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '存在多种未确认文件操作，请先结束使用并清理临时副本。',
      );
    }
    return WorkspaceFileActionState(
      pending: saved.pending ?? opened.pending,
      cleanupPending: saved.cleanupPending,
      openCopies: opened.openCopies,
      openCleanupPending: opened.openCleanupPending,
    );
  });

  Future<WorkspaceFileActionResult> action(
    WorkspaceRecordRef record,
    String key,
    int version,
    WorkspaceFileAction action,
    String id,
  ) => _run((d) async {
    // Local IDs cannot mask an already committed formal record/file operation.
    if (await files.receipt(id) != null || await client.receipt(id) != null) {
      throw const WorkspaceFailure('operation_conflict', '此编号已用于资料或文件更改。');
    }
    final pending = (await state(record, key)).pending;
    if (pending != null && pending.operationId != id) {
      throw const WorkspaceFailure('previous_pending', '原文件操作尚未确认，请先核对。');
    }
    if (action == WorkspaceFileAction.open) {
      if (await d.saved.receipt(id) != null) {
        throw const WorkspaceFailure('operation_conflict', '此编号已用于另存。');
      }
      return d.opened.open(record, key, version, id);
    }
    if (await d.opened.receipt(id) != null) {
      throw const WorkspaceFailure('operation_conflict', '此编号已用于打开。');
    }
    return d.saved.save(record, key, version, id);
  });
  Future<void> recoverAccess(String id) =>
      _run((d) => d.saved.recoverAccess(id));
  Future<void> cleanup(WorkspaceRecordRef r, String k) =>
      _run((d) => d.saved.cleanup(r, k));
  Future<void> finish(String id) => _run((d) => d.opened.finish(id));
  Future<void> closeCopies(WorkspaceRecordRef r, String k) =>
      _run((d) => d.opened.closeCopies(r, k));

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    final pending = _opening;
    if (pending == null) return;
    _DeviceActions d;
    try {
      d = await pending;
    } catch (_) {
      return;
    }
    d.context.closed = true;
    d.saved.dispose();
    d.opened.dispose();
    await d.context.drain;
    try {
      await d.store.fileOpens.maintain(closeAll: true);
      await d.saved.maintain();
    } finally {
      await d.store.close();
    }
  }
}

class _DeviceActions {
  _DeviceActions(this.store, this.context, this.saved, this.opened);
  final DeviceFileOperations store;
  final _RemoteFileContext context;
  final WorkspaceFileActions saved;
  final WorkspaceFileOpens opened;
}

class _RemoteFileContext implements WorkspaceFileActionContext {
  _RemoteFileContext(this.client, this.files, this.readDetail);
  final OwnerClient client;
  final RemoteWorkspaceFiles files;
  final Future<WorkspaceDetail> Function(WorkspaceRecordRef) readDetail;
  bool closed = false;
  Future<void> _queue = Future.value();
  Future<void> get drain => _queue;
  @override
  bool get isCurrent => !closed;
  @override
  void check() {
    if (closed) {
      throw const WorkspaceFailure('library_changed', '连接已关闭，请重新打开文件。');
    }
  }

  @override
  Future<T> run<T>(Future<T> Function() action) {
    final result = _queue.then((_) async {
      check();
      await client.request(
        'GET',
        '/v1/server',
      ); // No offline owner data/actions.
      check();
      return action();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<WorkspaceDetail> detail(WorkspaceRecordRef record) =>
      readDetail(record);
  @override
  Future<WorkspaceFileHistory> history(WorkspaceRecordRef record, String key) =>
      files.history(record, key);
  @override
  Future<WorkspaceFileOriginal> original(
    WorkspaceRecordRef record,
    String key,
    core.InformationAttachmentRef reference,
  ) async {
    final body = await files.original(record, key, reference.attachmentVersion);
    if (body.file.ref.id != reference.attachmentId) {
      throw const WorkspaceFailure('conflict', '文件绑定已变化，请重新打开资料。');
    }
    return body;
  }

  @override
  Future<void> assertCurrent(
    WorkspaceRecordRef record,
    String key,
    String? fieldId,
    core.InformationAttachmentRef reference,
  ) async {
    check();
    final current = await readDetail(record);
    final value = current.values[key];
    if (current.fieldIds[key] != fieldId ||
        value is! Map ||
        WorkspaceFileRef.fromJson(value).id != reference.attachmentId ||
        WorkspaceFileRef.fromJson(value).version !=
            reference.attachmentVersion) {
      throw const WorkspaceFailure('conflict', '文件已变化，请重新打开后核对。');
    }
  }
}
