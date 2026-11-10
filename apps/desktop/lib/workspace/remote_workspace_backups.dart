import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:info_workspace/backup_transport.dart';
import '../backups.dart';
import 'owner_workspace_backup_files.dart';
import 'workspace_source.dart';

part 'remote_workspace_backup_outputs.dart';

/// Online adapter for the original backup controller and native input/output
/// boundary. The only device database contains operation/publication facts.
class RemoteWorkspaceBackups
    implements WorkspaceBackupSource, WorkspaceBackupAccessRecovery {
  RemoteWorkspaceBackups(
    this.client, {
    required this.directory,
    required this.changed,
    this.picker = const NativeBackupFilePicker(),
  }) {
    files = OwnerWorkspaceBackupFiles.remote(
      checkBinding: _current,
      picker: picker,
    );
  }
  static const _base = '/v1/owner/backups';
  final OwnerClient client;
  final String? directory;
  final void Function() changed;
  final BackupFilePicker picker;
  late final OwnerWorkspaceBackupFiles files;
  Future<DeviceBackupOperations>? _opening;
  Future<void> _queue = Future.value();
  bool _closing = false, _closed = false;
  final _previews = <String, WorkspaceBackupPreview>{};
  final _uploads = <String, ({String id, String hash, int length})>{};
  void _current() {
    if (_closed) {
      throw const WorkspaceFailure('library_changed', '连接已关闭，请重新打开备份。');
    }
  }

  Future<DeviceBackupOperations> _store() async {
    _current();
    final path = directory;
    if (path == null) {
      throw const WorkspaceFailure('unavailable', '本机备份操作记录尚未接入。');
    }
    final scope = sha256.convert(utf8.encode(client.serverId)).toString();
    final opening = _opening ??= DeviceBackupOperations.open(
      '$path/backups/$scope',
      serverId: client.serverId,
    );
    try {
      return await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  WorkspaceFailure _error(Object e, {bool uncertain = false}) {
    if (e is WorkspaceFailure) return e;
    final code = e is RemoteFailure
        ? e.code
        : e is StorageFailure
        ? e.code
        : e is BackupPublicationFailure
        ? e.code
        : '';
    return switch (code) {
      'recipient_not_empty' => const WorkspaceFailure(
        'recipient_not_empty',
        '当前信息库已有资料或历史，不能覆盖或合并恢复。',
      ),
      'invalid_backup' => const WorkspaceFailure(
        'invalid_backup',
        '密钥不匹配、备份损坏或内容无效，当前信息库未改变。',
      ),
      'invalid_recovery_key' => const WorkspaceFailure(
        'invalid_recovery_key',
        '恢复密钥文件不正确，请重新选择。',
      ),
      'backup_changed' || 'backup_preview_expired' || 'selection_expired' =>
        const WorkspaceFailure('backup_changed', '文件或恢复预览已变化，请重新选择并检查。'),
      'unsupported_backup' => const WorkspaceFailure(
        'unsupported_backup',
        '此备份格式暂不支持。',
      ),
      'recovery_key_not_saved' => const WorkspaceFailure(
        'key_not_saved',
        '请先独立保存恢复密钥。',
      ),
      'operation_conflict' || 'backup_version_conflict' =>
        const WorkspaceFailure('conflict', '备份状态或原操作已变化，请刷新后核对。'),
      'output_exists' || 'backup_not_published' || 'not_submitted' =>
        const WorkspaceFailure('not_submitted', '原操作未完成；已有文件不会覆盖，请重新选择后操作。'),
      'backup_access_required' => const WorkspaceFailure(
        'backup_access_required',
        '需要重新选择上次另存的原文件以核对，不会重写文件。',
      ),
      'library_changed' || 'device_journal_scope_changed' =>
        const WorkspaceFailure('library_changed', '资料库或连接已变化，请重新打开备份。'),
      'backup_cleanup_pending' => const WorkspaceFailure(
        'cleanup_pending',
        '暂存尚未清理完成，已保存的文件不受影响。',
      ),
      _ => WorkspaceFailure(
        uncertain ? 'unknown_outcome' : 'unavailable',
        uncertain ? '原操作结果尚未确认，请核对原操作；不会重复另存或恢复。' : '备份服务暂不可用，请检查连接和文件位置后重试。',
      ),
    };
  }

  Future<T> _run<T>(Future<T> Function() action, {bool uncertain = false}) {
    if (_closing || _closed) {
      return Future.error(const WorkspaceFailure('unavailable', '备份连接已关闭。'));
    }
    final result = _queue.then((_) async {
      _current();
      try {
        return await action();
      } catch (e) {
        throw _error(e, uncertain: uncertain);
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<WorkspaceBackupResource?> pick(WorkspaceBackupPick kind) =>
      files.pick(kind);
  WorkspaceBackupChange _command(BackupOwnerIntent c) =>
      backupChangeFromJson({'wireVersion': 1, ...c.command});
  @override
  Future<WorkspaceBackupStatus> status() => _run(() async {
    final remote = backupStatusFromJson(await client.request('GET', _base));
    final store = await _store();
    final latest = await store.publication.latestExportOperation();
    final pending = await store.pending();
    final local = pending.firstOrNull;
    if (local != null &&
        remote.pending != null &&
        local.intent.digest != remote.pending!.command.digest) {
      throw const WorkspaceFailure('unknown_outcome', '存在另一项未确认备份，请先核对原操作。');
    }
    return WorkspaceBackupStatus(
      version: remote.version,
      keyCreated: remote.keyCreated,
      keySaved: remote.keySaved,
      recipientEmpty: remote.recipientEmpty,
      blockers: remote.blockers,
      cleanupCount:
          remote.cleanupCount +
          await store.publication.pendingOutputCleanupCount(),
      latestArchiveAt: latest?.completedAt,
      latestArchiveLocation: latest?.destination,
      latestArchive: latest == null
          ? remote.latestArchive
          : WorkspaceBackupResource(
              id: 'output_${latest.operationId}',
              name: latest.fileName,
              kind: WorkspaceBackupPick.archiveInput,
            ),
      pending: local == null
          ? remote.pending
          : WorkspaceBackupPending(
              _command(local.intent),
              restoreCounts: local.intent.restoreCounts == null
                  ? null
                  : backupCountsFromJson(local.intent.restoreCounts),
            ),
    );
  });
  Future<Map<String, dynamic>> _key() async {
    final key = backupEnvelope(
      await client.request('GET', '$_base/recovery-key'),
      ['recoveryKey', 'sha256', 'byteLength', 'version'],
    );
    final text = key['recoveryKey'];
    if (text is! String ||
        !RegExp(r'^aim-recovery-v1:[A-Za-z0-9_-]{43}=$').hasMatch(text)) {
      throw const FormatException();
    }
    final bytes = utf8.encode('$text\n');
    if (backupInt(key['byteLength'], min: 1, max: 256) != bytes.length ||
        backupHash(key['sha256']) != sha256.convert(bytes).toString()) {
      throw const FormatException();
    }
    backupInt(key['version'], min: 1);
    return key;
  }

  @override
  Future<String> revealRecoveryKey() =>
      _run(() async => (await _key())['recoveryKey'] as String);

  @override
  Future<WorkspaceBackupPreview> inspect(
    WorkspaceBackupResource archive,
    WorkspaceBackupResource key,
  ) => _run(() async {
    final store = await _store();
    if ((await store.pending()).isNotEmpty) {
      throw const WorkspaceFailure('unknown_outcome', '请先核对上次备份操作。');
    }
    final path = files.pathFor(archive, kind: WorkspaceBackupPick.archiveInput);
    final recovery = await store.publication.readRecoveryKeyFrom(
      files.pathFor(key, kind: WorkspaceBackupPick.keyInput),
    );
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const StorageFailure('invalid_backup');
    }
    final file = File(path);
    final length = await file.length();
    if (length < 4096 || length > AttachmentBackupContainer.maxFileBytes) {
      throw const StorageFailure('invalid_backup');
    }
    final hash = (await sha256.bind(file.openRead()).single).toString();
    final previous = _uploads[archive.id];
    final upload =
        (previous != null && previous.hash == hash && previous.length == length)
        ? previous
        : (id: workspaceOperationId(), hash: hash, length: length);
    if (previous != null && previous.id != upload.id) {
      await _dropUpload(previous.id);
    }
    _uploads[archive.id] = upload;
    final begun = backupEnvelope(
      await client.request('POST', '$_base/uploads', {
        'wireVersion': 1,
        'uploadId': upload.id,
        'resource': archive.json,
        'byteLength': length,
        'sha256': hash,
      }),
      ['uploadId', 'received'],
    );
    if (begun['uploadId'] != upload.id) throw const FormatException();
    var offset = backupInt(begun['received'], max: length);
    final input = await file.open();
    try {
      await input.setPosition(offset);
      while (offset < length) {
        final bytes = await input.read((length - offset).clamp(1, 512 * 1024));
        if (bytes.isEmpty) throw const StorageFailure('backup_changed');
        final r = backupEnvelope(
          await client.request('POST', '$_base/uploads/${upload.id}/chunks', {
            'wireVersion': 1,
            'offset': offset,
            'bytes': base64Encode(bytes),
          }),
          ['uploadId', 'received'],
        );
        offset += bytes.length;
        if (r['uploadId'] != upload.id || r['received'] != offset) {
          throw const FormatException();
        }
      }
    } finally {
      await input.close();
    }
    _current();
    files.pathFor(archive, kind: WorkspaceBackupPick.archiveInput);
    files.pathFor(key, kind: WorkspaceBackupPick.keyInput);
    if (length != await file.length() ||
        hash != (await sha256.bind(file.openRead()).single).toString()) {
      throw const StorageFailure('backup_changed');
    }
    final p = backupPreviewFromJson(
      await client.request('POST', '$_base/inspect', {
        'wireVersion': 1,
        'uploadId': upload.id,
        'archive': archive.json,
        'key': key.json,
        'recoveryKey': recovery,
      }),
    );
    if (!p.archive.same(archive) || !p.key.same(key)) {
      throw const FormatException();
    }
    _previews[p.token] = p;
    return p;
  });
  Future<void> _dropUpload(String id) async {
    await client.request('DELETE', '$_base/uploads/$id');
  }

  @override
  Future<void> releasePreview(String token) => _run(() async {
    await client.request('DELETE', '$_base/previews/${backupId(token)}');
    final p = _previews.remove(token);
    if (p != null &&
        !_previews.values.any((v) => v.archive.id == p.archive.id)) {
      final upload = _uploads.remove(p.archive.id);
      if (upload != null) await _dropUpload(upload.id);
    }
  });

  Future<WorkspaceBackupReceipt?> _serverReceipt(String id) async {
    try {
      return backupReceiptFromJson(
        await client.request('GET', '$_base/operations/${backupId(id)}'),
      );
    } on RemoteFailure catch (e) {
      if ({'operation_not_found', 'backup_not_published'}.contains(e.code)) {
        return null;
      }
      rethrow;
    }
  }

  Future<WorkspaceBackupReceipt?> _reconcile(String id) async {
    final store = await _store();
    final entry = await store.read(id);
    if (entry == null) {
      return _serverReceipt(
        id,
      ); // Another device: never infer its local save failed.
    }
    if (!entry.intent.pending) {
      return entry.result == null ? null : backupReceiptFromJson(entry.result);
    }
    final c = _command(entry.intent);
    WorkspaceBackupReceipt? result;
    if ({
      WorkspaceBackupAction.saveKey,
      WorkspaceBackupAction.export,
    }.contains(c.action)) {
      final native = await _withAccess(
        store,
        id,
        needsOutput:
            await store.publication.outputOperationPhase(id) ==
            BackupOutputPhase.publishing,
        action: () => store.publication.reconcileOutputOperation(id),
      );
      if (native != null) {
        if (native.commandDigest != c.digest || entry.outputHash == null) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        result = backupReceiptFromJson(
          await client.request('POST', '$_base/outputs/confirm', {
            'wireVersion': 1,
            'change': backupChangeToJson(c),
            'sha256': entry.outputHash,
          }),
        );
      } else if (c.action == WorkspaceBackupAction.export) {
        WorkspaceBackupTransfer? transfer;
        try {
          transfer = backupTransferFromJson(
            await client.request('GET', '$_base/exports/$id'),
          );
        } on RemoteFailure catch (e) {
          if (e.code != 'not_found') rethrow;
        }
        if (transfer != null) {
          if (transfer.command.digest != c.digest ||
              transfer.phase == 'saved') {
            throw const StorageFailure('backup_outcome_unknown');
          }
          if (transfer.phase == 'prepared') {
            await client.request('POST', '$_base/outputs/abandon', {
              'wireVersion': 1,
              'change': backupChangeToJson(c),
              'sha256': transfer.sha256,
            });
          }
        } else {
          result = await _serverReceipt(id);
          if (result != null) {
            throw const StorageFailure('backup_outcome_unknown');
          }
        }
      } else {
        result = await _serverReceipt(id);
        if (result != null) {
          throw const StorageFailure('backup_outcome_unknown');
        }
      }
    } else {
      result = await _serverReceipt(id);
    }
    if (result != null &&
        (!result.matches(c) ||
            c.action == WorkspaceBackupAction.restore &&
                !result.counts!.same(
                  backupCountsFromJson(entry.intent.restoreCounts),
                ))) {
      throw const StorageFailure('backup_outcome_unknown');
    }
    await store.settle(id, result == null ? null : backupReceiptToJson(result));
    try {
      await _cleanupOne(store, id);
    } catch (_) {
      /* Independent durable cleanup queue. */
    }
    if (result?.action == WorkspaceBackupAction.restore) {
      files.clear();
      _previews.clear();
      _uploads.clear();
    }
    changed();
    return result;
  }

  @override
  Future<WorkspaceBackupReceipt?> receipt(String operationId) =>
      _run(() => _reconcile(operationId), uncertain: true);
  @override
  Future<WorkspaceBackupReceipt> change(WorkspaceBackupChange c) => _run(
    () async {
      final store = await _store();
      final old = await store.read(c.operationId);
      if (old != null) {
        if (old.intent.digest != c.digest) {
          throw const WorkspaceFailure('conflict', '原操作编号已用于其他内容。');
        }
        return await _reconcile(c.operationId) ??
            (throw const WorkspaceFailure('not_submitted', '原操作未提交，请重新选择后操作。'));
      }
      final preview = _previews[c.previewToken];
      if (c.action == WorkspaceBackupAction.restore &&
          preview == null &&
          await store.read(c.operationId) == null) {
        throw const WorkspaceFailure('backup_changed', '恢复预览已失效，请重新选择并检查。');
      }
      final fresh = await store.record(
        c.json,
        restoreCounts: preview?.counts.json,
      );
      if (!fresh) {
        return await _reconcile(c.operationId) ??
            (throw const WorkspaceFailure('not_submitted', '原操作未提交，请重新选择后操作。'));
      }
      try {
        if ({
          WorkspaceBackupAction.saveKey,
          WorkspaceBackupAction.export,
        }.contains(c.action)) {
          await _produce(store, c);
          return await _reconcile(c.operationId) ??
              (throw const StorageFailure('backup_outcome_unknown'));
        }
        if (c.action == WorkspaceBackupAction.cleanup) await _cleanupAll(store);
        final result = backupReceiptFromJson(
          await client.request('POST', '$_base/changes', backupChangeToJson(c)),
        );
        if (!result.matches(c) ||
            c.action == WorkspaceBackupAction.restore &&
                !result.counts!.same(preview!.counts)) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        await store.settle(c.operationId, backupReceiptToJson(result));
        if (c.action == WorkspaceBackupAction.restore) {
          files.clear();
          _previews.clear();
          _uploads.clear();
        }
        changed();
        return result;
      } catch (e) {
        try {
          final found = await _reconcile(c.operationId);
          if (found != null) return found;
        } catch (check) {
          final failure = _error(check, uncertain: true);
          if (failure.code == 'backup_access_required') throw failure;
          throw const WorkspaceFailure(
            'unknown_outcome',
            '原操作结果仍未确认，请先核对；不会重复另存或恢复。',
          );
        }
        throw _error(e);
      }
    },
    uncertain: true,
  );

  @override
  Future<bool> requestRecoveryAccess(String operationId) async {
    try {
      return await _recoverAccess(operationId);
    } catch (e) {
      throw _error(e, uncertain: true);
    }
  }

  Future<void> dispose() async {
    if (_closing) return;
    _closing = true;
    await _queue;
    files.dispose();
    _previews.clear();
    final deletions = _uploads.values
        .map((u) => _dropUpload(u.id).catchError((Object _) {}))
        .toList();
    _uploads.clear();
    try {
      await Future.wait(deletions).timeout(const Duration(seconds: 3));
    } catch (_) {}
    final opening = _opening;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {}
    }
    _closed = true;
  }
}
