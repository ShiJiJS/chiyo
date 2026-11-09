import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/backup_transport.dart';
import 'package:info_workspace/workspace_source.dart';

part 'owner_backup_outputs.dart';

final class _BackupUpload {
  _BackupUpload(this.resource, this.path, this.bytes, this.digest, this.until);
  final WorkspaceBackupResource resource;
  final String path, digest;
  final int bytes;
  final Duration until;
}

/// Owner-only portable restore. The existing storage authenticates/decrypts the
/// archive and performs its atomic installation. Only encrypted archive bytes
/// are staged; the independent recovery key remains in the request/preview's
/// memory, never a server file, ordinary receipt or private runtime checkpoint.
/// Invoked inside OnlineInformationRuntime.run, never through AgentProtocol.
final class OwnerBackupRoutes {
  OwnerBackupRoutes({
    required this.owner,
    required this.backups,
    required this.directory,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _clock(),
       _scope = owner.captureLibraryScope();
  final OwnerAccess owner;
  final InformationBackups backups;
  final Directory directory;
  final Duration Function() _elapsed;
  OwnerLibraryScope _scope;
  static const lifetime = Duration(minutes: 30);
  static const chunkBytes = 512 * 1024;
  static const archiveBytes = AttachmentBackupContainer.maxFileBytes;
  final _uploads = <String, _BackupUpload>{};
  bool _inputSweepNeeded = true;
  bool _outputCleanupRequested = true;
  final _previews =
      <String, ({WorkspaceBackupPreview page, BackupRestorePreview storage})>{};
  static Duration Function() _clock() {
    final timer = Stopwatch()..start();
    return () => timer.elapsed;
  }

  String _id() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  WorkspaceBackupCounts _counts(Map<String, int> v) => backupCountsFromJson(v);
  WorkspaceBackupReceipt _receipt(BackupRestoreReceipt r) =>
      WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: WorkspaceBackupAction.restore,
        expectedVersion: r.expectedVersion,
        version: r.version,
        counts: _counts(r.counts),
        resource: WorkspaceBackupResource(
          id: r.archiveId,
          name: r.fileName,
          kind: WorkspaceBackupPick.archiveInput,
          version: r.archiveVersion,
        ),
      );

  bool get needsCleanup =>
      _inputSweepNeeded ||
      _outputCleanupRequested ||
      !_scope.isCurrent ||
      _uploads.values.any((v) => v.until <= _elapsed());

  Future<void> _release(String id) async {
    final upload = _uploads[id];
    if (upload == null) return;
    for (final entry in _previews.entries.toList()) {
      if (entry.value.page.archive.same(upload.resource)) {
        entry.value.storage.release();
        _previews.remove(entry.key);
      }
    }
    // Only this process's individually registered temporary directory is owned.
    await File(upload.path).parent.delete(recursive: true);
    _uploads.remove(id);
  }

  Future<void> cleanup() async {
    await _cleanupOutputs(forceOrphans: !_scope.isCurrent);
    if (_inputSweepNeeded) {
      // No preview survives a host restart. The dedicated transfer directory
      // may contain only this host's old encrypted incoming folders; never
      // remove one registered in this process or follow a filesystem link.
      final registered = _uploads.values
          .map((u) => File(u.path).parent.path)
          .toSet();
      await for (final entity in directory.list(followLinks: false)) {
        final name = entity.uri.pathSegments.where((v) => v.isNotEmpty).last;
        if (name.startsWith('incoming-') &&
            !registered.contains(entity.path) &&
            await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.directory) {
          await entity.delete(recursive: true);
        }
      }
      _inputSweepNeeded = false;
    }
    for (final entry in _uploads.entries.toList()) {
      if (!_scope.isCurrent || entry.value.until <= _elapsed()) {
        await _release(entry.key);
      }
    }
    if (!_scope.isCurrent) _scope = owner.captureLibraryScope();
  }

  Future<void> dispose() async {
    for (final id in _uploads.keys.toList()) {
      await _release(id);
    }
  }

  Future<WorkspaceBackupStatus> status() => owner.exportLibrary(() async {
    final empty = await backups.recipientEmpty();
    final pending = await backups.pendingOwnerOperations();
    final saved =
        (await backups.remoteOutputs())
            .where(
              (r) =>
                  r.action == BackupOutputAction.export &&
                  r.phase == BackupRemoteOutputPhase.saved,
            )
            .toList()
          ..sort((a, b) => b.version.compareTo(a.version));
    return WorkspaceBackupStatus(
      version: await backups.operationVersion(),
      keyCreated: await backups.recoveryKey() != null,
      keySaved: await backups.recoveryKeySaved(),
      recipientEmpty: empty,
      blockers: empty ? [] : ['已有资料或历史，不能覆盖或合并恢复'],
      cleanupCount:
          _uploads.values.where((v) => v.until <= _elapsed()).length +
          (_outputCleanupRequested ? 1 : 0),
      latestArchive: saved.isEmpty
          ? null
          : _remoteReceipt(saved.first).resource,
      pending: pending.isEmpty
          ? null
          : WorkspaceBackupPending(
              backupChangeFromJson({
                'wireVersion': 1,
                ...pending.single.command,
              }),
              restoreCounts: pending.single.restoreCounts == null
                  ? null
                  : _counts(pending.single.restoreCounts!),
            ),
    );
  });

  Future<Map<String, Object?>> _begin(Object? raw) async {
    final v = backupEnvelope(raw, [
      'uploadId',
      'resource',
      'byteLength',
      'sha256',
    ]);
    final id = backupId(v['uploadId']);
    final r = backupResourceFromJson(v['resource']);
    final bytes = backupInt(v['byteLength'], min: 4096, max: archiveBytes);
    final digest = backupHash(v['sha256']);
    if (r.kind != WorkspaceBackupPick.archiveInput)
      throw const FormatException();
    final previous = _uploads[id];
    if (previous != null) {
      if (!r.same(previous.resource) ||
          bytes != previous.bytes ||
          digest != previous.digest) {
        throw const WorkspaceFailure('operation_conflict', '原上传不能用于其他备份。');
      }
      return {
        'wireVersion': 1,
        'uploadId': id,
        'received': await File(previous.path).length(),
      };
    }
    if (_uploads.length >= 4 ||
        _uploads.values.fold<int>(0, (n, u) => n + u.bytes) + bytes >
            archiveBytes) {
      throw const WorkspaceFailure('capacity', '备份暂存已满，请取消旧选择后重试。');
    }
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const StorageFailure('backup_staging_failed');
    }
    final folder = await directory.createTemp('incoming-');
    try {
      if ((await Process.run('/bin/chmod', ['700', folder.path])).exitCode !=
          0) {
        throw const StorageFailure('backup_staging_failed');
      }
      final file = File('${folder.path}/${r.name}');
      await file.create(exclusive: true);
      _uploads[id] = _BackupUpload(
        r,
        file.path,
        bytes,
        digest,
        _elapsed() + lifetime,
      );
      return {'wireVersion': 1, 'uploadId': id, 'received': 0};
    } catch (_) {
      _inputSweepNeeded = true;
      await folder.delete(recursive: true);
      rethrow;
    }
  }

  _BackupUpload _upload(String id) =>
      _uploads[id] ??
      (throw const WorkspaceFailure('selection_expired', '备份选择已失效，请重新选择。'));

  Future<Map<String, Object?>> _chunk(String id, Object? raw) async {
    final upload = _upload(id);
    final v = backupEnvelope(raw, ['offset', 'bytes']);
    final offset = backupInt(v['offset'], max: upload.bytes);
    final encoded = v['bytes'];
    if (encoded is! String || encoded.length > ((chunkBytes + 2) ~/ 3) * 4)
      throw const FormatException();
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty ||
        bytes.length > chunkBytes ||
        offset + bytes.length > upload.bytes)
      throw const FormatException();
    final file = await File(upload.path).open(mode: FileMode.append);
    try {
      final current = await file.length();
      if (offset < current) {
        if (offset + bytes.length > current) throw const FormatException();
        final reader = await File(upload.path).open();
        try {
          await reader.setPosition(offset);
          if (base64Encode(await reader.read(bytes.length)) !=
              base64Encode(bytes)) {
            throw const WorkspaceFailure(
              'operation_conflict',
              '原分块内容不同，请重新选择备份。',
            );
          }
        } finally {
          await reader.close();
        }
      } else {
        if (offset != current) throw const FormatException();
        await file.writeFrom(bytes);
        await file.flush();
      }
      return {
        'wireVersion': 1,
        'uploadId': id,
        'received': await file.length(),
      };
    } finally {
      await file.close();
    }
  }

  Future<WorkspaceBackupPreview> _inspect(Object? raw) =>
      owner.exportLibrary(() async {
        final v = backupEnvelope(raw, [
          'uploadId',
          'archive',
          'key',
          'recoveryKey',
        ]);
        final upload = _upload(backupId(v['uploadId']));
        final archive = backupResourceFromJson(v['archive']);
        final key = backupResourceFromJson(v['key']);
        if (!upload.resource.same(archive) ||
            key.kind != WorkspaceBackupPick.keyInput ||
            v['recoveryKey'] is! String ||
            (v['recoveryKey'] as String).length > 256)
          throw const FormatException();
        if (_previews.length >= 16)
          throw const WorkspaceFailure('capacity', '请先关闭旧的恢复预览。');
        final file = File(upload.path);
        if (await file.length() != upload.bytes ||
            (await sha256.bind(file.openRead()).single).toString() !=
                upload.digest) {
          throw const StorageFailure('backup_changed');
        }
        final checked = await backups.inspectRestore(
          path: upload.path,
          recoveryKey: v['recoveryKey'] as String,
          archiveId: archive.id,
          archiveVersion: archive.version,
        );
        final page = WorkspaceBackupPreview(
          token: _id(),
          archive: archive,
          key: key,
          counts: _counts(checked.counts),
          createdAt: checked.createdAt,
          formatLabel: '加密备份 · 格式 ${checked.formatVersion}',
        );
        _previews[page.token] = (page: page, storage: checked);
        return page;
      });

  Future<WorkspaceBackupReceipt?> receipt(String id) =>
      owner.exportLibrary(() => _storedReceipt(id));

  Future<WorkspaceBackupReceipt?> _storedReceipt(String id) async {
    final action = await backups.backupOperationAction(id);
    final intent = await backups.ownerOperationIntent(id);
    if (action == null) {
      if (intent != null)
        await backups.acknowledgeOwnerOperation(id, intent.digest);
      return null;
    }
    late WorkspaceBackupReceipt result;
    if (action == 'restore') {
      result = _receipt((await backups.restoreOperationReceipt(id))!);
    } else if (action == 'enableKey') {
      final r = (await backups.recoveryKeyOperationReceipt(id))!;
      result = WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: WorkspaceBackupAction.enableKey,
        expectedVersion: r.expectedVersion,
        version: r.version,
      );
    } else if (action == 'cleanup') {
      final r = (await backups.cleanupOperationReceipt(id))!;
      result = WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: r.commandDigest,
        action: WorkspaceBackupAction.cleanup,
        expectedVersion: r.expectedVersion,
        version: r.version,
      );
    } else if (action == 'remoteOutput') {
      final r = (await backups.remoteOutputReceipt(id))!;
      if (r.phase == BackupRemoteOutputPhase.prepared) {
        throw const WorkspaceFailure('output_pending', '原备份已生成，本机文件是否保存还需核对。');
      }
      if (r.phase == BackupRemoteOutputPhase.abandoned) {
        if (intent != null)
          await backups.acknowledgeOwnerOperation(id, intent.digest);
        throw const StorageFailure('backup_not_published');
      }
      result = _remoteReceipt(r);
    } else {
      throw const StorageFailure('operation_conflict');
    }
    if (intent != null) {
      final command = backupChangeFromJson({
        'wireVersion': 1,
        ...intent.command,
      });
      if (!result.matches(command) ||
          action == 'restore' &&
              (intent.restoreCounts == null ||
                  !result.counts!.same(_counts(intent.restoreCounts!)))) {
        throw const StorageFailure('invalid_backup_operation_receipt');
      }
      await backups.acknowledgeOwnerOperation(id, intent.digest);
    }
    return result;
  }

  Future<WorkspaceBackupReceipt> _restore(WorkspaceBackupChange c) async {
    if (c.action != WorkspaceBackupAction.restore) {
      throw const WorkspaceFailure('unavailable', '此操作尚未接通。');
    }
    final r = await owner.restoreLibraryOnce<BackupRestoreReceipt>(
      previous: () async {
        final old = await backups.restoreOperationReceipt(c.operationId);
        if (old != null) {
          if (!_receipt(old).matches(c))
            throw const StorageFailure('operation_conflict');
          return old;
        }
        final intent = await backups.ownerOperationIntent(c.operationId);
        if (intent != null) {
          if (intent.digest != c.digest)
            throw const StorageFailure('operation_conflict');
          throw const WorkspaceFailure('not_submitted', '原恢复未提交，请重新选择并检查。');
        }
        final p = _previews[c.previewToken];
        if (p == null ||
            c.selection == null ||
            !p.page.archive.same(c.selection!)) {
          throw const StorageFailure('backup_preview_expired');
        }
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
    // The existing barrier has already invalidated runtime identities. A lost
    // acknowledgement never repeats installation; lookup returns the receipt.
    try {
      await backups.acknowledgeOwnerOperation(c.operationId, c.digest);
    } catch (_) {}
    _previews.remove(c.previewToken)?.storage.release();
    return _receipt(r);
  }

  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    await cleanup();
    final tail = path.skip(3).toList();
    if (method == 'GET' && tail.isEmpty)
      return (200, backupStatusToJson(await status()));
    if (method == 'POST' && tail.length == 1 && tail.first == 'uploads')
      return (200, await _begin(body));
    if (tail.length == 3 &&
        tail.first == 'uploads' &&
        tail.last == 'chunks' &&
        method == 'POST') {
      return (200, await _chunk(backupId(tail[1]), body));
    }
    if (tail.length == 2 && tail.first == 'uploads' && method == 'DELETE') {
      await _release(backupId(tail.last));
      return (200, {'status': 'released'});
    }
    if (tail.length == 1 && tail.first == 'inspect' && method == 'POST') {
      return (200, backupPreviewToJson(await _inspect(body)));
    }
    if (tail.length == 2 && tail.first == 'previews' && method == 'DELETE') {
      _previews.remove(backupId(tail.last))?.storage.release();
      return (200, {'status': 'released'});
    }
    if (tail.length == 1 && tail.first == 'recovery-key' && method == 'GET') {
      return (200, await _recoveryKey());
    }
    if (tail.length == 1 && tail.first == 'exports' && method == 'POST') {
      return (
        200,
        backupTransferToJson(
          _transfer(await _prepareExport(backupChangeFromJson(body))),
        ),
      );
    }
    if (tail.length == 2 && tail.first == 'exports' && method == 'GET') {
      return (
        200,
        backupTransferToJson(_transfer(await _export(backupId(tail.last)))),
      );
    }
    if (tail.length == 3 &&
        tail.first == 'exports' &&
        tail.last == 'chunks' &&
        method == 'POST') {
      return (200, await _download(backupId(tail[1]), body));
    }
    if (tail.length == 2 &&
        tail.first == 'outputs' &&
        tail.last == 'confirm' &&
        method == 'POST') {
      return (200, backupReceiptToJson(await _confirmOutput(body)));
    }
    if (tail.length == 2 &&
        tail.first == 'outputs' &&
        tail.last == 'abandon' &&
        method == 'POST') {
      await _abandonOutput(body);
      return (200, {'status': 'abandoned'});
    }
    if (tail.length == 1 && tail.first == 'changes' && method == 'POST') {
      return (
        200,
        backupReceiptToJson(await _change(backupChangeFromJson(body))),
      );
    }
    if (tail.length == 2 && tail.first == 'operations' && method == 'GET') {
      final r = await receipt(backupId(tail.last));
      return (
        r == null ? 404 : 200,
        r == null ? {'error': 'operation_not_found'} : backupReceiptToJson(r),
      );
    }
    return (404, {'error': 'not_found'});
  }
}
