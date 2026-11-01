part of 'info_storage.dart';

/// An authenticated Owner-only preview bound to this open recipient and archive.
/// Paths and recovery material stay in memory; release drops the source handle.
final class BackupRestorePreview {
  BackupRestorePreview._({
    required this.archiveId,
    required this.fileName,
    required this.archiveVersion,
    required this.expectedVersion,
    required this.createdAt,
    required this.formatVersion,
    required Map<String, int> counts,
    required InformationBackups owner,
    required _AttachmentBackupOrigin source,
  }) : counts = Map.unmodifiable(counts),
       _owner = owner,
       _source = source;
  final String archiveId, fileName;
  final int archiveVersion, expectedVersion, formatVersion;
  final DateTime createdAt;
  final Map<String, int> counts;
  final InformationBackups _owner;
  _AttachmentBackupOrigin? _source;
  void release() => _source = null;
}

/// Local durable acknowledgement, never a source handle or restored capability.
final class BackupRestoreReceipt {
  BackupRestoreReceipt._({
    required this.operationId,
    required this.commandDigest,
    required this.expectedVersion,
    required this.version,
    required this.archiveId,
    required this.fileName,
    required this.archiveVersion,
    required Map<String, int> counts,
  }) : counts = Map.unmodifiable(counts);
  final String operationId, commandDigest, archiveId, fileName;
  final int expectedVersion, version, archiveVersion;
  final Map<String, int> counts;
  Map<String, Object?> toJson() => {
    'format': 3,
    'action': 'restore',
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'version': version,
    'archiveId': archiveId,
    'fileName': fileName,
    'archiveVersion': archiveVersion,
    'counts': counts,
  };
}

final class _BackupRestoreIntent {
  _BackupRestoreIntent(this.id, this.digest, this.preview);
  final String id, digest;
  final BackupRestorePreview preview;
  BackupRestoreReceipt? receipt;
}

extension BackupRestoreOperations on InformationBackups {
  void _validateRestoreResource(String id, String name, int version) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
        version < 1 ||
        name.isEmpty ||
        name == '.' ||
        name == '..' ||
        utf8.encode(name).length > 255 ||
        RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name)) {
      throw const StorageFailure('invalid_backup_operation');
    }
  }

  // Bounded hash of the encrypted archive, not plaintext or recovery material.
  Future<String> _restoreArchiveDigest(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const StorageFailure('invalid_backup');
    }
    var bytes = 0;
    final stream = File(path).openRead().map((chunk) {
      bytes += chunk.length;
      if (bytes > AttachmentBackupContainer.maxFileBytes) {
        throw const StorageFailure('invalid_backup');
      }
      return chunk;
    });
    return (await crypto.sha256.bind(stream).single).toString();
  }

  Future<BackupRestorePreview> inspectRestore({
    required String path,
    required String recoveryKey,
    required String archiveId,
    required int archiveVersion,
  }) async {
    _checkOpen();
    final name = File(path).uri.pathSegments.last;
    _validateRestoreResource(archiveId, name, archiveVersion);
    try {
      final version = await operationVersion();
      if (!await recipientEmpty())
        throw const StorageFailure('recipient_not_empty');
      final digest = await _restoreArchiveDigest(path);
      final contents = await inspect(path, recoveryKey);
      if (digest != await _restoreArchiveDigest(path)) {
        throw const StorageFailure('backup_changed');
      }
      if (version != await operationVersion()) {
        throw const StorageFailure('backup_version_conflict');
      }
      if (!await recipientEmpty())
        throw const StorageFailure('recipient_not_empty');
      return BackupRestorePreview._(
        archiveId: archiveId,
        fileName: name,
        archiveVersion: archiveVersion,
        expectedVersion: version,
        createdAt: contents.createdAt,
        formatVersion: contents.formatVersion,
        counts: _outputCounts(
          _retain(contents, _repository._clock().toUtc(), restored: true),
        ),
        owner: this,
        source: _AttachmentBackupOrigin(path, recoveryKey, digest),
      );
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('invalid_backup');
    }
  }

  BackupRestoreReceipt _decodeRestoreReceipt(Map<String, dynamic> value) {
    try {
      if (value.length != 10 ||
          value['format'] != 3 ||
          value['action'] != 'restore') {
        throw const FormatException();
      }
      final id = value['operationId'] as String;
      final digest = value['commandDigest'] as String;
      final expected = value['expectedVersion'] as int;
      final version = value['version'] as int;
      final archiveId = value['archiveId'] as String;
      final name = value['fileName'] as String;
      final archiveVersion = value['archiveVersion'] as int;
      final counts = (value['counts'] as Map).cast<String, int>();
      _validateKeyOperation(id, digest, expected);
      _validateRestoreResource(archiveId, name, archiveVersion);
      if (version != expected + 1 ||
          counts.length != _backupCountNames.length ||
          !counts.keys.toSet().containsAll(_backupCountNames) ||
          counts.values.any((n) => n < 0)) {
        throw const FormatException();
      }
      return BackupRestoreReceipt._(
        operationId: id,
        commandDigest: digest,
        expectedVersion: expected,
        version: version,
        archiveId: archiveId,
        fileName: name,
        archiveVersion: archiveVersion,
        counts: counts,
      );
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  /// Read-only reconciliation. Null is actual absence; never starts a restore.
  Future<BackupRestoreReceipt?> restoreOperationReceipt(String id) async {
    final payload = await _backupOperationPayload(id);
    if (payload == null) return null;
    if (payload['action'] != 'restore')
      throw const StorageFailure('operation_conflict');
    return _decodeRestoreReceipt(payload);
  }

  bool _sameRestoreCounts(Map<String, int> a, Map<String, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// The caller holds the Owner restore barrier. Repeat acknowledgement must be
  /// checked before entering that barrier, so new sessions are not reset again.
  /// Data, old-operation invalidation, version and this receipt commit together.
  Future<BackupRestoreReceipt> restoreWithReceipt({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required BackupRestorePreview preview,
  }) async {
    _checkOpen();
    _validateKeyOperation(operationId, commandDigest, expectedVersion);
    if (expectedVersion != preview.expectedVersion) {
      throw const StorageFailure('backup_version_conflict');
    }
    try {
      final previous = await restoreOperationReceipt(operationId);
      if (previous != null) {
        if (previous.commandDigest != commandDigest ||
            previous.expectedVersion != expectedVersion ||
            previous.archiveId != preview.archiveId ||
            previous.fileName != preview.fileName ||
            previous.archiveVersion != preview.archiveVersion ||
            !_sameRestoreCounts(previous.counts, preview.counts)) {
          throw const StorageFailure('operation_conflict');
        }
        return previous;
      }
      final source = preview._source;
      if (!identical(preview._owner, this) || source == null) {
        throw const StorageFailure('backup_preview_expired');
      }
      if (await operationVersion() != expectedVersion) {
        throw const StorageFailure('backup_version_conflict');
      }
      if (source.fingerprint != await _restoreArchiveDigest(source.path)) {
        throw const StorageFailure('backup_changed');
      }
      final current = await inspect(source.path, source.key);
      if (source.fingerprint != await _restoreArchiveDigest(source.path)) {
        throw const StorageFailure('backup_changed');
      }
      final intent = _BackupRestoreIntent(operationId, commandDigest, preview);
      if (current.formatVersion >= 8) {
        await _restoreAttachmentBackup(current, intent: intent);
      } else {
        await _installBackup(current, intent: intent);
      }
      preview.release();
      return intent.receipt!;
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_restore_failed');
    }
  }

  Future<void> _checkRestoreIntent(
    _BackupRestoreIntent intent,
    BackupContents contents,
  ) async {
    if (intent.preview._source == null) {
      throw const StorageFailure('backup_preview_expired');
    }
    // Recheck under the same write transaction as installation. A second caller
    // cannot silently replay a commit that raced its initial read-only lookup.
    if (await _backupOperationPayload(intent.id) != null) {
      throw const StorageFailure('operation_conflict');
    }
    if (await operationVersion() != intent.preview.expectedVersion) {
      throw const StorageFailure('backup_version_conflict');
    }
    if (!_sameRestoreCounts(_outputCounts(contents), intent.preview.counts)) {
      throw const StorageFailure('backup_preview_expired');
    }
  }

  Future<void> _commitRestoreReceipt(
    _BackupRestoreIntent intent,
    BackupContents contents,
  ) async {
    final p = intent.preview;
    if (p._source == null) {
      throw const StorageFailure('backup_preview_expired');
    }
    final receipt = BackupRestoreReceipt._(
      operationId: intent.id,
      commandDigest: intent.digest,
      expectedVersion: p.expectedVersion,
      version: await operationVersion(),
      archiveId: p.archiveId,
      fileName: p.fileName,
      archiveVersion: p.archiveVersion,
      counts: _outputCounts(contents),
    );
    await _repository._db.customStatement(
      'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
      [intent.id, jsonEncode(receipt.toJson())],
    );
    intent.receipt = receipt;
  }
}
