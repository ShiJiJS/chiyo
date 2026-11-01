part of 'info_storage.dart';

enum BackupOutputAction { saveKey, export }

enum BackupOutputPhase { prepared, publishing, succeeded, notPublished }

/// The fact of a completed output, not a capability to read or rewrite it.
final class BackupOutputReceipt {
  BackupOutputReceipt._(_BackupOutputRecord record)
    : operationId = record.id,
      commandDigest = record.digest,
      expectedVersion = record.expectedVersion,
      version = record.version,
      action = record.action,
      fileName = File(record.publication.destination).uri.pathSegments.last,
      counts = Map.unmodifiable(record.counts);
  final String operationId, commandDigest, fileName;
  final int expectedVersion, version;
  final BackupOutputAction action;
  final Map<String, int> counts;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'version': version,
    'action': action.name,
    'fileName': fileName,
    'counts': counts,
  };
}

final class _BackupOutputRecord {
  _BackupOutputRecord({
    required this.id,
    required this.digest,
    required this.expectedVersion,
    required this.version,
    required this.action,
    required this.publication,
    required Map<String, int> counts,
    this.phase = BackupOutputPhase.prepared,
    this.cleanupPending = true,
  }) : counts = Map.unmodifiable(counts);
  final String id, digest;
  final int expectedVersion, version;
  final BackupOutputAction action;
  final MacBackupPublication publication;
  final Map<String, int> counts;
  final BackupOutputPhase phase;
  final bool cleanupPending;
  _BackupOutputRecord change({
    BackupOutputPhase? phase,
    bool? cleanupPending,
    int? version,
  }) => _BackupOutputRecord(
    id: id,
    digest: digest,
    expectedVersion: expectedVersion,
    version: version ?? this.version,
    action: action,
    publication: publication,
    counts: counts,
    phase: phase ?? this.phase,
    cleanupPending: cleanupPending ?? this.cleanupPending,
  );
  Map<String, Object?> toPrivateJson() => {
    'format': 2,
    'operationId': id,
    'commandDigest': digest,
    'expectedVersion': expectedVersion,
    'version': version,
    'action': action.name,
    'publication': publication.toPrivateJson(),
    'counts': counts,
    'phase': phase.name,
    'cleanupPending': cleanupPending,
  };
}

const _backupCountNames = {
  'information',
  'credentials',
  'materials',
  'files',
  'fileBytes',
  'directories',
  'tags',
  'templates',
  'plugins',
  'legacyTemplates',
  'revisions',
  'recycled',
  'grants',
  'operations',
  'hosts',
};

extension BackupOutputOperations on InformationBackups {
  Future<Map<String, dynamic>?> _backupOperationPayload(String id) async {
    _checkOpen();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw const StorageFailure('invalid_backup_operation');
    }
    final rows = await _repository._db
        .customSelect(
          'SELECT payload,invalidated FROM backup_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0) {
      throw const StorageFailure('library_changed');
    }
    try {
      final result =
          jsonDecode(rows.single.read<String>('payload'))
              as Map<String, dynamic>;
      if (result['operationId'] != id) throw const FormatException();
      return result;
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  /// Dispatch information for an Owner adapter; null is actual absence.
  /// Invalidated or malformed records must not become absence or trigger replay.
  Future<String?> backupOperationAction(String id) async {
    final payload = await _backupOperationPayload(id);
    if (payload == null) return null;
    if (payload['action'] == 'enableKey') {
      await recoveryKeyOperationReceipt(id);
      return 'enableKey';
    }
    if (payload['action'] == 'restore') {
      _decodeRestoreReceipt(payload);
      return 'restore';
    }
    return _decodeOutput(payload).action.name;
  }

  _BackupOutputRecord _decodeOutput(Map<String, dynamic> json) {
    try {
      if (json.length != 10 ||
          json['format'] != 2 ||
          json['cleanupPending'] is! bool ||
          json['counts'] is! Map ||
          json['expectedVersion'] is! int ||
          json['version'] is! int) {
        throw const FormatException();
      }
      final id = json['operationId'] as String,
          digest = json['commandDigest'] as String;
      final expected = json['expectedVersion'] as int,
          version = json['version'] as int;
      _validateKeyOperation(id, digest, expected);
      final action = BackupOutputAction.values.byName(json['action'] as String);
      final phase = BackupOutputPhase.values.byName(json['phase'] as String);
      if (version <= expected ||
          {
                BackupOutputPhase.prepared,
                BackupOutputPhase.publishing,
              }.contains(phase) &&
              version != expected + 1)
        throw const FormatException();
      final counts = (json['counts'] as Map).cast<String, int>();
      if (counts.values.any((n) => n < 0) ||
          (action == BackupOutputAction.saveKey
              ? counts.isNotEmpty
              : counts.length != _backupCountNames.length ||
                    !counts.keys.toSet().containsAll(_backupCountNames)) ||
          !json['cleanupPending'] &&
              {
                BackupOutputPhase.prepared,
                BackupOutputPhase.publishing,
              }.contains(phase)) {
        throw const FormatException();
      }
      return _BackupOutputRecord(
        id: id,
        digest: digest,
        expectedVersion: expected,
        version: version,
        action: action,
        publication: MacBackupPublication.fromPrivateJson(
          json['publication'] as Map<String, dynamic>,
        ),
        counts: counts,
        phase: phase,
        cleanupPending: json['cleanupPending'] as bool,
      );
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  Future<_BackupOutputRecord?> _outputRecord(String id) async {
    final value = await _backupOperationPayload(id);
    if (value == null) return null;
    if (value['action'] == 'enableKey' || value['action'] == 'restore')
      throw const StorageFailure('operation_conflict');
    return _decodeOutput(value);
  }

  Future<void> _writeOutput(
    _BackupOutputRecord value,
  ) => _repository._db.customStatement(
    'UPDATE backup_operations SET payload=? WHERE operation_id=? AND invalidated=0',
    [jsonEncode(value.toPrivateJson()), value.id],
  );

  Map<String, int> _outputCounts(BackupContents p) => {
    'information': p.informationCount,
    'credentials': p.credentialCount,
    'materials': p.credentialVersionCount,
    'files': p.attachmentCount,
    'fileBytes': p.attachmentBytes,
    'directories': p.directoryCount,
    'tags': p.tagCount,
    'templates': 0,
    'plugins': 0,
    'legacyTemplates': p.templateCount,
    'revisions': p.revisionCount,
    'recycled': p.recycleCount,
    'grants': p.grantHistoryCount,
    'operations':
        p.accessRecordCount +
        p.requestHistoryCount +
        p.credentialUseHistoryCount +
        p.credentialExecutionCount +
        p.focusedFillCount +
        p.fileDeliveryCount,
    'hosts': p.sshTrustCount,
  };

  /// Register an authenticated prepared file BEFORE exposing it at the output.
  /// The caller owns the staging lease and holds the Owner export barrier while
  /// producing/registering/publishing it. This API never creates file contents.
  /// Identical repeat registrations do not regain permission to publish.
  Future<void> prepareOutputOperation({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required BackupOutputAction action,
    required MacBackupPublication publication,
  }) async {
    try {
      await _prepareOutputOperation(
        operationId: operationId,
        commandDigest: commandDigest,
        expectedVersion: expectedVersion,
        action: action,
        publication: publication,
      );
    } on StorageFailure {
      rethrow;
    } on BackupPublicationFailure catch (error) {
      throw StorageFailure(error.code);
    } on Object {
      throw const StorageFailure('backup_operation_failed');
    }
  }

  Future<void> _prepareOutputOperation({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required BackupOutputAction action,
    required MacBackupPublication publication,
  }) async {
    _checkOpen();
    _validateKeyOperation(operationId, commandDigest, expectedVersion);
    final created = await _repository._db.transaction(() async {
      final previous = await _outputRecord(operationId);
      if (previous != null) {
        if (previous.digest != commandDigest ||
            previous.expectedVersion != expectedVersion ||
            previous.action != action ||
            jsonEncode(previous.publication.toPrivateJson()) !=
                jsonEncode(publication.toPrivateJson())) {
          throw const StorageFailure('operation_conflict');
        }
        return false;
      }
      if (await operationVersion() != expectedVersion)
        throw const StorageFailure('backup_version_conflict');
      final key = await recoveryKey();
      if (key == null) throw const StorageFailure('backup_not_enabled');
      MacBackupPublicationFiles.verifyPrepared(publication);
      late Map<String, int> counts;
      if (action == BackupOutputAction.saveKey) {
        if (await readRecoveryKeyFrom(publication.source) != key) {
          throw const StorageFailure('invalid_recovery_key');
        }
        counts = const {};
      } else {
        if (!await recoveryKeySaved())
          throw const StorageFailure('recovery_key_not_saved');
        counts = _outputCounts(await inspect(publication.source, key));
      }
      MacBackupPublicationFiles.verifyPrepared(publication);
      final record = _BackupOutputRecord(
        id: operationId,
        digest: commandDigest,
        expectedVersion: expectedVersion,
        version: expectedVersion + 1,
        action: action,
        publication: publication,
        counts: counts,
      );
      await _repository._db.customStatement(
        'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
        [operationId, jsonEncode(record.toPrivateJson())],
      );
      await _advanceOperationVersion();
      return true;
    });
    if (created) _preparedBackupOutputs.add(operationId);
  }

  Future<BackupOutputReceipt> _finishOutput(
    String id,
  ) => _repository._db.transaction(() async {
    final value = await _outputRecord(id);
    if (value == null) throw const StorageFailure('backup_operation_missing');
    if (value.phase == BackupOutputPhase.succeeded)
      return BackupOutputReceipt._(value);
    if (value.phase != BackupOutputPhase.publishing ||
        MacBackupPublicationFiles.confirmPublished(value.publication) !=
            BackupPublicationObservation.matching) {
      throw const StorageFailure('backup_outcome_unknown');
    }
    if (value.action == BackupOutputAction.saveKey) {
      if (await readRecoveryKeyFrom(value.publication.source) !=
          await recoveryKey()) {
        throw const StorageFailure('backup_outcome_unknown');
      }
      await _repository._db.customStatement(
        'UPDATE backup_configuration SET recovery_saved=1 WHERE singleton=1',
      );
    }
    await _advanceOperationVersion();
    final completed = value.change(
      phase: BackupOutputPhase.succeeded,
      version: await operationVersion(),
    );
    await _writeOutput(completed);
    return BackupOutputReceipt._(completed);
  });

  /// At most one publish attempt, only from a freshly registered in-process
  /// intent. Reopen/retry can observe the original result, never republish.
  Future<BackupOutputReceipt> publishOutputOperation(String id) async {
    _checkOpen();
    if (!_activeBackupOutputs.add(id))
      throw const StorageFailure('backup_operation_busy');
    try {
      if (!_preparedBackupOutputs.remove(id)) {
        final receipt = await _reconcileOutput(id);
        if (receipt != null) return receipt;
        throw const StorageFailure('backup_not_published');
      }
      final value = await _repository._db.transaction(() async {
        final record = await _outputRecord(id);
        if (record == null || record.phase != BackupOutputPhase.prepared) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        await _writeOutput(record.change(phase: BackupOutputPhase.publishing));
        return record;
      });
      try {
        MacBackupPublicationFiles.publish(value.publication);
      } on BackupPublicationFailure catch (error) {
        // flush_failed can occur AFTER rename. All other driver failures occur
        // before it; record that definite failure before reporting it as such.
        if (error.code != 'flush_failed') {
          await _repository._db.transaction(() async {
            final current = await _outputRecord(id);
            if (current == null ||
                current.phase != BackupOutputPhase.publishing) {
              throw const StorageFailure('backup_outcome_unknown');
            }
            await _advanceOperationVersion();
            await _writeOutput(
              current.change(
                phase: BackupOutputPhase.notPublished,
                version: await operationVersion(),
              ),
            );
          });
          throw const StorageFailure('backup_not_published');
        }
        throw const StorageFailure('backup_outcome_unknown');
      }
      return await _finishOutput(id);
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_outcome_unknown');
    } finally {
      _activeBackupOutputs.remove(id);
    }
  }

  Future<BackupOutputReceipt?> _reconcileOutput(String id) async {
    final value = await _outputRecord(id);
    if (value == null || value.phase == BackupOutputPhase.notPublished)
      return null;
    if (value.phase == BackupOutputPhase.succeeded)
      return BackupOutputReceipt._(value);
    if (value.phase == BackupOutputPhase.prepared) {
      // No process may publish until the publishing phase has committed. A
      // reconciled preparation is abandoned; resubmission needs a new intent.
      await _repository._db.transaction(() async {
        final current = await _outputRecord(id);
        if (current == null || current.phase != BackupOutputPhase.prepared) {
          throw const StorageFailure('backup_outcome_unknown');
        }
        await _advanceOperationVersion();
        await _writeOutput(
          current.change(
            phase: BackupOutputPhase.notPublished,
            version: await operationVersion(),
          ),
        );
      });
      _preparedBackupOutputs.remove(id);
      return null;
    }
    return _finishOutput(id);
  }

  Future<BackupOutputReceipt?> reconcileOutputOperation(String id) async {
    _checkOpen();
    if (!_activeBackupOutputs.add(id))
      throw const StorageFailure('backup_operation_busy');
    try {
      return await _reconcileOutput(id);
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_outcome_unknown');
    } finally {
      _activeBackupOutputs.remove(id);
    }
  }

  Future<BackupOutputPhase?> outputOperationPhase(String id) async =>
      (await _outputRecord(id))?.phase;

  /// Cleanup is separate from success. Its failure never undoes a saved receipt.
  /// Only the registered temporary names are removed; directories/native leases
  /// remain the caller's responsibility. Pending publication retains its anchor.
  Future<void> cleanupOutputOperation(String id) async {
    _checkOpen();
    if (!_activeBackupOutputs.add(id))
      throw const StorageFailure('backup_operation_busy');
    try {
      final value = await _outputRecord(id);
      if (value == null || !value.cleanupPending) return;
      if (!{
        BackupOutputPhase.succeeded,
        BackupOutputPhase.notPublished,
      }.contains(value.phase)) {
        throw const StorageFailure('backup_outcome_unknown');
      }
      MacBackupPublicationFiles.cleanup(value.publication);
      await _repository._db.transaction(() async {
        final current = await _outputRecord(id);
        if (current == null || current.phase != value.phase)
          throw const StorageFailure('backup_outcome_unknown');
        await _writeOutput(current.change(cleanupPending: false));
        await _advanceOperationVersion();
      });
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_cleanup_pending');
    } finally {
      _activeBackupOutputs.remove(id);
    }
  }

  Future<int> pendingOutputCleanupCount() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          'SELECT operation_id FROM backup_operations WHERE invalidated=0',
        )
        .get();
    var count = 0;
    for (final row in rows) {
      final id = row.read<String>('operation_id');
      final action = await backupOperationAction(id);
      if (action == 'enableKey' || action == 'restore') continue;
      if ((await _outputRecord(id))!.cleanupPending) count++;
    }
    return count;
  }
}
