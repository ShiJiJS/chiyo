part of 'info_storage.dart';

final class _BackupStagingRecord {
  _BackupStagingRecord({
    required this.operationId,
    required this.outputId,
    required this.digest,
    required this.expectedVersion,
    required this.outputAction,
    required this.destination,
    required this.root,
    this.child,
    this.cleanupPending = true,
  });
  final String operationId, outputId, digest, destination;
  final int expectedVersion;
  final BackupOutputAction outputAction;
  final MacBackupStagingDirectory root;
  final MacBackupStagingDirectory? child;
  final bool cleanupPending;
  _BackupStagingRecord change({
    MacBackupStagingDirectory? child,
    bool? cleanupPending,
  }) => _BackupStagingRecord(
    operationId: operationId,
    outputId: outputId,
    digest: digest,
    expectedVersion: expectedVersion,
    outputAction: outputAction,
    destination: destination,
    root: root,
    child: child ?? this.child,
    cleanupPending: cleanupPending ?? this.cleanupPending,
  );
  Map<String, Object?> toPrivateJson() => {
    'format': 4,
    'action': 'staging',
    'operationId': operationId,
    'outputId': outputId,
    'commandDigest': digest,
    'expectedVersion': expectedVersion,
    'outputAction': outputAction.name,
    'destination': destination,
    'root': root.toPrivateJson(),
    'child': child?.toPrivateJson(),
    'cleanupPending': cleanupPending,
  };
}

extension BackupStagingOperations on InformationBackups {
  String _stagingId(String outputId) =>
      'backup_stage_${crypto.sha256.convert(utf8.encode(outputId))}';

  _BackupStagingRecord _decodeStaging(Map<String, dynamic> value) {
    try {
      if (value.length != 11 ||
          value['format'] != 4 ||
          value['action'] != 'staging') {
        throw const FormatException();
      }
      final outputId = value['outputId'] as String,
          digest = value['commandDigest'] as String;
      final version = value['expectedVersion'] as int;
      _validateKeyOperation(outputId, digest, version);
      final id = value['operationId'] as String;
      if (id != _stagingId(outputId)) throw const FormatException();
      final root = MacBackupStagingDirectory.fromPrivateJson(
        value['root'] as Map<String, dynamic>,
      );
      final child = value['child'] == null
          ? null
          : MacBackupStagingDirectory.fromPrivateJson(
              value['child'] as Map<String, dynamic>,
            );
      final destination = value['destination'] as String;
      if (!File(destination).isAbsolute ||
          destination.contains('\x00') ||
          destination == root.path ||
          destination.startsWith('${root.path}/') ||
          child != null &&
              (Directory(child.path).parent.path != root.path ||
                  child.parentIdentity != root.identity)) {
        throw const FormatException();
      }
      return _BackupStagingRecord(
        operationId: id,
        outputId: outputId,
        digest: digest,
        expectedVersion: version,
        outputAction: BackupOutputAction.values.byName(
          value['outputAction'] as String,
        ),
        destination: destination,
        root: root,
        child: child,
        cleanupPending: value['cleanupPending'] as bool,
      );
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  // Cleanup reads tombstones too: changing libraries invalidates replay, not
  // ownership of exact temporary directories previously created on this device.
  Future<Map<String, dynamic>?> _localBackupRecord(
    String id, {
    bool invalidated = false,
  }) async {
    if (!invalidated) return _backupOperationPayload(id);
    final rows = await _repository._db
        .customSelect(
          'SELECT payload FROM backup_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    try {
      final value =
          jsonDecode(rows.single.read<String>('payload'))
              as Map<String, dynamic>;
      if (value['operationId'] != id) throw const FormatException();
      return value;
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  Future<_BackupStagingRecord?> _stagingFor(
    String id, {
    bool invalidated = false,
  }) async {
    final value = await _localBackupRecord(
      _stagingId(id),
      invalidated: invalidated,
    );
    return value == null ? null : _decodeStaging(value);
  }

  Future<void> _writeStaging(_BackupStagingRecord record) =>
      _repository._db.customStatement(
        'UPDATE backup_operations SET payload=? WHERE operation_id=?',
        [jsonEncode(record.toPrivateJson()), record.operationId],
      );

  /// Register a native-created EMPTY private same-volume directory before any
  /// material is written. The caller holds the Owner export barrier throughout
  /// production/publication. A previously registered intent cannot produce again.
  /// This reserves cleanup ownership, not a successful output or a new version
  /// of backup configuration. Output preparation still consumes expectedVersion.
  Future<void> registerOutputStaging({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required BackupOutputAction action,
    required String directory,
    required String destination,
  }) async {
    _checkOpen();
    _validateKeyOperation(operationId, commandDigest, expectedVersion);
    try {
      await _repository._db.transaction(() async {
        if (await _backupOperationPayload(operationId) != null ||
            await _stagingFor(operationId) != null) {
          throw const StorageFailure('operation_conflict');
        }
        if (await operationVersion() != expectedVersion)
          throw const StorageFailure('backup_version_conflict');
        if (await recoveryKey() == null)
          throw const StorageFailure('backup_not_enabled');
        if (action == BackupOutputAction.export && !await recoveryKeySaved())
          throw const StorageFailure('recovery_key_not_saved');
        final record = _BackupStagingRecord(
          operationId: _stagingId(operationId),
          outputId: operationId,
          digest: commandDigest,
          expectedVersion: expectedVersion,
          outputAction: action,
          destination: destination,
          root: MacBackupPublicationFiles.captureStaging(directory),
        );
        _decodeStaging(record.toPrivateJson().cast<String, dynamic>());
        await _repository._db.customStatement(
          'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
          [record.operationId, jsonEncode(record.toPrivateJson())],
        );
      });
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_staging_failed');
    }
  }

  /// Pass this to exportTo.onStagingCreated. It runs before SQLCipher creates
  /// backup.partial, including attachment exports; a failed registration aborts.
  Future<void> registerOutputStagingChild(
    String operationId,
    String directory,
  ) async {
    _checkOpen();
    try {
      await _repository._db.transaction(() async {
        final record = await _stagingFor(operationId);
        if (record == null ||
            !record.cleanupPending ||
            record.child != null ||
            record.outputAction != BackupOutputAction.export ||
            await _backupOperationPayload(operationId) != null ||
            await operationVersion() != record.expectedVersion ||
            Directory(directory).parent.path != record.root.path ||
            !MacBackupPublicationFiles.stagingExists(record.root)) {
          throw const StorageFailure('backup_staging_failed');
        }
        final child = MacBackupPublicationFiles.captureStaging(directory);
        if (child.parentIdentity != record.root.identity)
          throw const StorageFailure('backup_staging_failed');
        await _writeStaging(record.change(child: child));
      });
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_staging_failed');
    }
  }

  Future<void> _checkStagedPublication(
    String id,
    String digest,
    int expected,
    BackupOutputAction action,
    MacBackupPublication publication,
  ) async {
    final record = await _stagingFor(id);
    if (record == null) return; // Existing low-level callers own their staging.
    if (!record.cleanupPending ||
        record.digest != digest ||
        record.expectedVersion != expected ||
        record.outputAction != action ||
        record.destination != publication.destination ||
        publication.source != '${record.root.path}/prepared' ||
        publication.sourceDirectoryIdentity != record.root.identity ||
        !MacBackupPublicationFiles.stagingExists(record.root)) {
      throw const StorageFailure('operation_conflict');
    }
  }

  /// Owner-only recovery/cleanup queue, including old-library tombstones.
  Future<List<String>> pendingOutputStaging() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect('SELECT payload FROM backup_operations')
        .get();
    final result = <String>[];
    for (final row in rows) {
      Map<String, dynamic> value;
      try {
        value = jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      } on Object {
        throw const StorageFailure('invalid_backup_operation_receipt');
      }
      if (value['action'] != 'staging') continue;
      final record = _decodeStaging(value);
      if (record.cleanupPending) result.add(record.outputId);
    }
    return List.unmodifiable(result);
  }

  /// Cleans only registered private generated names. A publication whose result
  /// is unknown retains its anchor. Tombstones can be cleaned but never replayed.
  /// The Owner adapter holds its backup barrier and may release its native
  /// allocation with an idempotent callback before cleanup is acknowledged.
  Future<void> cleanupRegisteredOutputStaging(
    String operationId, {
    Future<void> Function()? releaseNative,
  }) async {
    _checkOpen();
    if (!_activeBackupOutputs.add(operationId))
      throw const StorageFailure('backup_operation_busy');
    try {
      final record = await _stagingFor(operationId, invalidated: true);
      if (record == null || !record.cleanupPending) return;
      final payload = await _localBackupRecord(operationId, invalidated: true);
      var output = payload == null ? null : _decodeOutput(payload);
      if (output != null &&
          (output.digest != record.digest ||
              output.expectedVersion != record.expectedVersion ||
              output.action != record.outputAction ||
              output.publication.source != '${record.root.path}/prepared' ||
              output.publication.destination != record.destination ||
              output.publication.sourceDirectoryIdentity !=
                  record.root.identity)) {
        throw const StorageFailure('operation_conflict');
      }
      if (output?.phase == BackupOutputPhase.publishing)
        throw const StorageFailure('backup_outcome_unknown');
      if (output?.phase == BackupOutputPhase.prepared) {
        _preparedBackupOutputs.remove(operationId);
        await _repository._db.transaction(() async {
          await _advanceOperationVersion();
          output = output!.change(
            phase: BackupOutputPhase.notPublished,
            version: await operationVersion(),
          );
          await _repository._db.customStatement(
            'UPDATE backup_operations SET payload=? WHERE operation_id=?',
            [jsonEncode(output!.toPrivateJson()), operationId],
          );
        });
      }
      if (MacBackupPublicationFiles.stagingExists(record.root)) {
        if (output != null && output!.cleanupPending)
          MacBackupPublicationFiles.cleanup(output!.publication);
        if (record.child != null)
          MacBackupPublicationFiles.cleanupStaging(
            record.child!,
            generatedFiles: const {
              'backup.partial',
              'backup.partial-journal',
              'backup.partial-wal',
              'backup.partial-shm',
            },
          );
        MacBackupPublicationFiles.cleanupStaging(
          record.root,
          generatedFiles: const {'prepared', 'prepared.publish'},
        );
      }
      await releaseNative?.call();
      await _repository._db.transaction(() async {
        await _writeStaging(record.change(cleanupPending: false));
        if (output != null) {
          await _repository._db.customStatement(
            'UPDATE backup_operations SET payload=? WHERE operation_id=?',
            [
              jsonEncode(output!.change(cleanupPending: false).toPrivateJson()),
              operationId,
            ],
          );
        }
        await _advanceOperationVersion();
      });
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_cleanup_pending');
    } finally {
      _activeBackupOutputs.remove(operationId);
    }
  }
}
