part of 'info_storage.dart';

enum BackupRemoteOutputPhase { prepared, saved, abandoned }

/// Encrypted host acknowledgement of a portable snapshot or an independently
/// saved recovery key. Preparation is NOT proof that the device saved a file.
/// No filesystem path, recovery key or reusable access proof is a receipt.
final class BackupRemoteOutput {
  BackupRemoteOutput._({
    required this.operationId,
    required this.commandDigest,
    required this.expectedVersion,
    required this.version,
    required this.action,
    required this.fileName,
    required this.resourceId,
    required this.resourceVersion,
    required this.contentDigest,
    required this.byteLength,
    required Map<String, int> counts,
    required this.artifactId,
    required this.phase,
  }) : counts = Map.unmodifiable(counts);
  final String operationId, commandDigest, fileName, resourceId, contentDigest;
  final String? artifactId;
  final int expectedVersion, version, resourceVersion, byteLength;
  final BackupOutputAction action;
  final BackupRemoteOutputPhase phase;
  final Map<String, int> counts;
  Map<String, Object?> toJson() => {
    'format': 7,
    'action': 'remoteOutput',
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'version': version,
    'outputAction': action.name,
    'fileName': fileName,
    'resourceId': resourceId,
    'resourceVersion': resourceVersion,
    'contentDigest': contentDigest,
    'byteLength': byteLength,
    'counts': counts,
    'artifactId': artifactId,
    'phase': phase.name,
  };
  BackupRemoteOutput _withPhase(BackupRemoteOutputPhase value) =>
      BackupRemoteOutput._(
        operationId: operationId,
        commandDigest: commandDigest,
        expectedVersion: expectedVersion,
        version: version,
        action: action,
        fileName: fileName,
        resourceId: resourceId,
        resourceVersion: resourceVersion,
        contentDigest: contentDigest,
        byteLength: byteLength,
        counts: counts,
        artifactId: artifactId,
        phase: value,
      );
}

extension RemoteBackupOutputs on InformationBackups {
  BackupRemoteOutput _decodeRemoteOutput(Map<String, dynamic> v) {
    try {
      if (v.length != 15 || v['format'] != 7 || v['action'] != 'remoteOutput')
        throw const FormatException();
      final r = BackupRemoteOutput._(
        operationId: v['operationId'] as String,
        commandDigest: v['commandDigest'] as String,
        expectedVersion: v['expectedVersion'] as int,
        version: v['version'] as int,
        action: BackupOutputAction.values.byName(v['outputAction'] as String),
        fileName: v['fileName'] as String,
        resourceId: v['resourceId'] as String,
        resourceVersion: v['resourceVersion'] as int,
        contentDigest: v['contentDigest'] as String,
        byteLength: v['byteLength'] as int,
        counts: (v['counts'] as Map).cast<String, int>(),
        artifactId: v['artifactId'] as String?,
        phase: BackupRemoteOutputPhase.values.byName(v['phase'] as String),
      );
      _validateKeyOperation(r.operationId, r.commandDigest, r.expectedVersion);
      _validateRestoreResource(r.resourceId, r.fileName, r.resourceVersion);
      if (r.version != r.expectedVersion + 1 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(r.contentDigest) ||
          r.byteLength < 1 ||
          r.byteLength > AttachmentBackupContainer.maxFileBytes ||
          (r.action == BackupOutputAction.saveKey
              ? r.artifactId != null ||
                    r.counts.isNotEmpty ||
                    r.phase != BackupRemoteOutputPhase.saved ||
                    r.byteLength > 256
              : r.artifactId == null ||
                    !RegExp(r'^[0-9a-f]{64}$').hasMatch(r.artifactId!) ||
                    !_validBackupCounts(r.counts))) {
        throw const FormatException();
      }
      return r;
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  Future<BackupRemoteOutput?> remoteOutputReceipt(String id) async {
    final v = await _backupOperationPayload(id);
    if (v == null) return null;
    if (v['action'] != 'remoteOutput')
      throw const StorageFailure('operation_conflict');
    return _decodeRemoteOutput(v);
  }

  Future<List<BackupRemoteOutput>> remoteOutputs() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          'SELECT payload FROM backup_operations WHERE invalidated=0',
        )
        .get();
    final outputs = <BackupRemoteOutput>[];
    for (final row in rows) {
      final value =
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      if (value['action'] == 'remoteOutput')
        outputs.add(_decodeRemoteOutput(value));
    }
    return List.unmodifiable(outputs);
  }

  void _remoteMatches(
    BackupRemoteOutput r,
    String digest,
    int version,
    BackupOutputAction action,
    String resourceId,
    String name,
    int resourceVersion,
  ) {
    if (r.commandDigest != digest ||
        r.expectedVersion != version ||
        r.action != action ||
        r.resourceId != resourceId ||
        r.fileName != name ||
        r.resourceVersion != resourceVersion) {
      throw const StorageFailure('operation_conflict');
    }
  }

  Future<void> _writeRemoteOutput(
    BackupRemoteOutput r, {
    bool insert = false,
  }) async {
    // Round-trip validation protects the storage boundary as well as decoding.
    _decodeRemoteOutput(Map<String, dynamic>.from(r.toJson()));
    await _repository._db.customStatement(
      insert
          ? 'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)'
          : 'UPDATE backup_operations SET payload=? WHERE operation_id=?',
      insert
          ? [r.operationId, jsonEncode(r.toJson())]
          : [jsonEncode(r.toJson()), r.operationId],
    );
  }

  /// Called only after the trusted device publisher has confirmed the user's
  /// independent key file. Matching a digest avoids resending plaintext here.
  Future<BackupRemoteOutput> recordRemoteRecoveryKeySaved({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required String resourceId,
    required String fileName,
    required int resourceVersion,
    required String contentDigest,
  }) async {
    _checkOpen();
    _validateKeyOperation(operationId, commandDigest, expectedVersion);
    return _repository._db.transaction(() async {
      final old = await remoteOutputReceipt(operationId);
      if (old != null) {
        _remoteMatches(
          old,
          commandDigest,
          expectedVersion,
          BackupOutputAction.saveKey,
          resourceId,
          fileName,
          resourceVersion,
        );
        if (old.contentDigest != contentDigest)
          throw const StorageFailure('operation_conflict');
        return old;
      }
      if (await operationVersion() != expectedVersion)
        throw const StorageFailure('backup_version_conflict');
      final key = await recoveryKey();
      if (key == null) throw const StorageFailure('backup_not_enabled');
      final bytes = utf8.encode('$key\n');
      if (crypto.sha256.convert(bytes).toString() != contentDigest)
        throw const StorageFailure('invalid_recovery_key');
      final r = BackupRemoteOutput._(
        operationId: operationId,
        commandDigest: commandDigest,
        expectedVersion: expectedVersion,
        version: expectedVersion + 1,
        action: BackupOutputAction.saveKey,
        resourceId: resourceId,
        resourceVersion: resourceVersion,
        fileName: fileName,
        contentDigest: contentDigest,
        byteLength: bytes.length,
        counts: {},
        artifactId: null,
        phase: BackupRemoteOutputPhase.saved,
      );
      await _writeRemoteOutput(r, insert: true);
      await _repository._db.customStatement(
        'UPDATE backup_configuration SET recovery_saved=1 WHERE singleton=1',
      );
      await _advanceOperationVersion();
      return r;
    });
  }

  /// Authenticate the already-produced encrypted snapshot before recording its
  /// original manifest. The host holds Owner.exportLibrary and keeps that exact
  /// artifact until the device confirms saving or explicitly abandons it.
  Future<BackupRemoteOutput> recordRemoteBackupPrepared({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required String resourceId,
    required String fileName,
    required int resourceVersion,
    required String artifactId,
    required String encryptedPath,
  }) async {
    _checkOpen();
    _validateKeyOperation(operationId, commandDigest, expectedVersion);
    return _repository._db.transaction(() async {
      final old = await remoteOutputReceipt(operationId);
      if (old != null) {
        _remoteMatches(
          old,
          commandDigest,
          expectedVersion,
          BackupOutputAction.export,
          resourceId,
          fileName,
          resourceVersion,
        );
        return old;
      }
      if (await operationVersion() != expectedVersion)
        throw const StorageFailure('backup_version_conflict');
      final key = await recoveryKey();
      if (key == null) throw const StorageFailure('backup_not_enabled');
      if (!await recoveryKeySaved())
        throw const StorageFailure('recovery_key_not_saved');
      final before = await _restoreArchiveDigest(encryptedPath);
      final snapshot = await inspect(encryptedPath, key);
      if (before != await _restoreArchiveDigest(encryptedPath))
        throw const StorageFailure('backup_changed');
      final r = BackupRemoteOutput._(
        operationId: operationId,
        commandDigest: commandDigest,
        expectedVersion: expectedVersion,
        version: expectedVersion + 1,
        action: BackupOutputAction.export,
        resourceId: resourceId,
        resourceVersion: resourceVersion,
        fileName: fileName,
        contentDigest: before,
        byteLength: await File(encryptedPath).length(),
        counts: _outputCounts(snapshot),
        artifactId: artifactId,
        phase: BackupRemoteOutputPhase.prepared,
      );
      await _writeRemoteOutput(r, insert: true);
      await _advanceOperationVersion();
      return r;
    });
  }

  Future<BackupRemoteOutput> finishRemoteBackupOutput(
    String id,
    String digest,
    String contentDigest, {
    required bool saved,
  }) async {
    _checkOpen();
    return _repository._db.transaction(() async {
      final old = await remoteOutputReceipt(id);
      if (old == null) throw const StorageFailure('backup_operation_missing');
      if (old.action != BackupOutputAction.export ||
          old.commandDigest != digest ||
          old.contentDigest != contentDigest) {
        throw const StorageFailure('operation_conflict');
      }
      final phase = saved
          ? BackupRemoteOutputPhase.saved
          : BackupRemoteOutputPhase.abandoned;
      if (old.phase != BackupRemoteOutputPhase.prepared) {
        if (old.phase != phase)
          throw const StorageFailure('operation_conflict');
        return old;
      }
      final r = old._withPhase(phase);
      await _writeRemoteOutput(r);
      return r;
    });
  }
}
