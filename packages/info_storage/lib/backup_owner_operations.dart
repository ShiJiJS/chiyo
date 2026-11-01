part of 'info_storage.dart';

/// Content-free Owner intent used to resume an unknown UI operation. Only
/// opaque selections, filenames, versions and counts; never paths or keys.
final class BackupOwnerIntent {
  BackupOwnerIntent._(
    Map<String, Object?> command,
    this.digest,
    Map<String, int>? counts,
    this.pending,
  ) : command = Map.unmodifiable({
        ...command,
        if (command['selection'] != null)
          'selection': Map<String, Object?>.unmodifiable(
            command['selection'] as Map,
          ),
      }),
      restoreCounts = counts == null ? null : Map.unmodifiable(counts);
  final Map<String, Object?> command;
  final String digest;
  final Map<String, int>? restoreCounts;
  final bool pending;
  String get operationId => command['operationId'] as String;
  String get action => command['action'] as String;
  int get expectedVersion => command['expectedVersion'] as int;
}

final class BackupCleanupReceipt {
  const BackupCleanupReceipt._(
    this.operationId,
    this.commandDigest,
    this.expectedVersion,
    this.version,
  );
  final String operationId, commandDigest;
  final int expectedVersion, version;
  Map<String, Object?> toJson() => {
    'format': 6,
    'action': 'cleanup',
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'version': version,
  };
}

extension BackupOwnerOperations on InformationBackups {
  String _ownerIntentId(String id) =>
      'backup_owner_${crypto.sha256.convert(utf8.encode(id))}';

  BackupOwnerIntent _checkedOwnerCommand(
    Map<String, Object?> input,
    Map<String, int>? counts,
    bool pending,
  ) {
    try {
      if (input.length != 5 ||
          !input.keys.toSet().containsAll({
            'operationId',
            'action',
            'expectedVersion',
            'selection',
            'previewToken',
          }))
        throw const FormatException();
      final id = input['operationId'] as String,
          action = input['action'] as String;
      final version = input['expectedVersion'] as int;
      if (!{
        'enableKey',
        'saveKey',
        'export',
        'restore',
        'cleanup',
      }.contains(action))
        throw const FormatException();
      Map<String, Object?>? selection;
      if ({'saveKey', 'export', 'restore'}.contains(action)) {
        selection = (input['selection'] as Map).cast<String, Object?>();
        if (selection.length != 4 ||
            !selection.keys.toSet().containsAll({
              'id',
              'name',
              'kind',
              'version',
            }))
          throw const FormatException();
        _validateRestoreResource(
          selection['id'] as String,
          selection['name'] as String,
          selection['version'] as int,
        );
        if (selection['kind'] !=
            switch (action) {
              'saveKey' => 'keyOutput',
              'export' => 'archiveOutput',
              _ => 'archiveInput',
            })
          throw const FormatException();
        selection = {
          'id': selection['id'],
          'name': selection['name'],
          'kind': selection['kind'],
          'version': selection['version'],
        };
      } else if (input['selection'] != null) {
        throw const FormatException();
      }
      final token = input['previewToken'];
      if (action == 'restore') {
        if (token is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(token) ||
            counts == null ||
            counts.length != _backupCountNames.length ||
            !counts.keys.toSet().containsAll(_backupCountNames) ||
            counts.values.any((n) => n < 0))
          throw const FormatException();
      } else if (token != null || counts != null) {
        throw const FormatException();
      }
      final command = <String, Object?>{
        'operationId': id,
        'action': action,
        'expectedVersion': version,
        'selection': selection,
        'previewToken': token,
      };
      final digest = crypto.sha256
          .convert(utf8.encode(jsonEncode(command)))
          .toString();
      _validateKeyOperation(id, digest, version);
      return BackupOwnerIntent._(command, digest, counts, pending);
    } on Object {
      throw const StorageFailure('invalid_backup_operation');
    }
  }

  Map<String, Object?> _ownerIntentPayload(
    BackupOwnerIntent intent, {
    bool? pending,
  }) => {
    'format': 5,
    'action': 'ownerIntent',
    'operationId': _ownerIntentId(intent.operationId),
    'command': intent.command,
    'commandDigest': intent.digest,
    'restoreCounts': intent.restoreCounts,
    'pending': pending ?? intent.pending,
  };
  BackupOwnerIntent _decodeOwnerIntent(Map<String, dynamic> value) {
    try {
      if (value.length != 7 ||
          value['format'] != 5 ||
          value['action'] != 'ownerIntent')
        throw const FormatException();
      final intent = _checkedOwnerCommand(
        (value['command'] as Map).cast<String, Object?>(),
        value['restoreCounts'] == null
            ? null
            : (value['restoreCounts'] as Map).cast<String, int>(),
        value['pending'] as bool,
      );
      if (value['operationId'] != _ownerIntentId(intent.operationId) ||
          value['commandDigest'] != intent.digest)
        throw const FormatException();
      return intent;
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  Future<bool> _currentOwnerIntent(
    BackupOwnerIntent intent,
    int invalidated,
  ) async {
    if (invalidated == 0) return true;
    if (intent.action != 'restore') return false;
    // Restore invalidates old intents. Only its own surviving success receipt
    // can carry a pending acknowledgement into the restored library.
    try {
      final receipt = await restoreOperationReceipt(intent.operationId);
      return receipt != null &&
          receipt.commandDigest == intent.digest &&
          receipt.expectedVersion == intent.expectedVersion;
    } on StorageFailure catch (e) {
      if (e.code == 'library_changed') return false;
      rethrow;
    }
  }

  Future<BackupOwnerIntent?> ownerOperationIntent(String id) async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          'SELECT payload,invalidated FROM backup_operations WHERE operation_id=?',
          variables: [Variable(_ownerIntentId(id))],
        )
        .get();
    if (rows.isEmpty) return null;
    Map<String, dynamic> payload;
    try {
      payload =
          jsonDecode(rows.single.read<String>('payload'))
              as Map<String, dynamic>;
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
    final intent = _decodeOwnerIntent(payload);
    if (intent.operationId != id)
      throw const StorageFailure('invalid_backup_operation_receipt');
    if (!await _currentOwnerIntent(
      intent,
      rows.single.read<int>('invalidated'),
    ))
      throw const StorageFailure('library_changed');
    return intent;
  }

  Future<List<BackupOwnerIntent>> pendingOwnerOperations() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          'SELECT operation_id,payload,invalidated FROM backup_operations',
        )
        .get();
    final pending = <BackupOwnerIntent>[];
    for (final row in rows) {
      Map<String, dynamic> value;
      try {
        value = jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      } on Object {
        throw const StorageFailure('invalid_backup_operation_receipt');
      }
      if (value['action'] != 'ownerIntent') continue;
      final intent = _decodeOwnerIntent(value);
      if (row.read<String>('operation_id') !=
          _ownerIntentId(intent.operationId))
        throw const StorageFailure('invalid_backup_operation_receipt');
      if (intent.pending &&
          await _currentOwnerIntent(intent, row.read<int>('invalidated')))
        pending.add(intent);
    }
    if (pending.length > 1)
      throw const StorageFailure('backup_outcome_unknown');
    return List.unmodifiable(pending);
  }

  /// True only for a newly persisted intent. Duplicates may only reconcile,
  /// never reproduce material or restore again. Caller holds the Owner lock.
  Future<bool> registerOwnerOperation(
    Map<String, Object?> command, {
    Map<String, int>? restoreCounts,
  }) async {
    _checkOpen();
    final intent = _checkedOwnerCommand(command, restoreCounts, true);
    try {
      return await _repository._db.transaction(() async {
        final previous = await ownerOperationIntent(intent.operationId);
        if (previous != null) {
          if (previous.digest != intent.digest ||
              (previous.restoreCounts == null
                  ? intent.restoreCounts != null
                  : intent.restoreCounts == null ||
                        !_sameRestoreCounts(
                          previous.restoreCounts!,
                          intent.restoreCounts!,
                        )))
            throw const StorageFailure('operation_conflict');
          return false;
        }
        if ((await pendingOwnerOperations()).isNotEmpty)
          throw const StorageFailure('backup_outcome_unknown');
        if (await operationVersion() != intent.expectedVersion)
          throw const StorageFailure('backup_version_conflict');
        await _repository._db.customStatement(
          'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
          [
            _ownerIntentId(intent.operationId),
            jsonEncode(_ownerIntentPayload(intent)),
          ],
        );
        return true;
      });
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_operation_failed');
    }
  }

  Future<void> acknowledgeOwnerOperation(String id, String digest) async {
    _checkOpen();
    await _repository._db.transaction(() async {
      final intent = await ownerOperationIntent(id);
      if (intent == null || intent.digest != digest)
        throw const StorageFailure('operation_conflict');
      if (!intent.pending) return;
      await _repository._db.customStatement(
        'UPDATE backup_operations SET payload=? WHERE operation_id=?',
        [
          jsonEncode(_ownerIntentPayload(intent, pending: false)),
          _ownerIntentId(id),
        ],
      );
    });
  }

  BackupCleanupReceipt _decodeCleanupReceipt(Map<String, dynamic> value) {
    try {
      if (value.length != 6 ||
          value['format'] != 6 ||
          value['action'] != 'cleanup')
        throw const FormatException();
      final id = value['operationId'] as String,
          digest = value['commandDigest'] as String;
      final expected = value['expectedVersion'] as int,
          version = value['version'] as int;
      _validateKeyOperation(id, digest, expected);
      if (version <= expected) throw const FormatException();
      return BackupCleanupReceipt._(id, digest, expected, version);
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  Future<BackupCleanupReceipt?> cleanupOperationReceipt(String id) async {
    final value = await _backupOperationPayload(id);
    if (value == null) return null;
    if (value['action'] != 'cleanup')
      throw const StorageFailure('operation_conflict');
    return _decodeCleanupReceipt(value);
  }

  Future<BackupCleanupReceipt> finishOwnerCleanup(String id) async {
    _checkOpen();
    return _repository._db.transaction(() async {
      final intent = await ownerOperationIntent(id);
      if (intent == null || intent.action != 'cleanup')
        throw const StorageFailure('operation_conflict');
      final previous = await cleanupOperationReceipt(id);
      if (previous != null) {
        if (previous.commandDigest != intent.digest)
          throw const StorageFailure('operation_conflict');
        return previous;
      }
      if (!intent.pending) throw const StorageFailure('operation_conflict');
      if (await pendingOutputCleanupCount() != 0)
        throw const StorageFailure('backup_cleanup_pending');
      if (await operationVersion() < intent.expectedVersion)
        throw const StorageFailure('backup_version_conflict');
      await _advanceOperationVersion();
      final receipt = BackupCleanupReceipt._(
        id,
        intent.digest,
        intent.expectedVersion,
        await operationVersion(),
      );
      await _repository._db.customStatement(
        'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
        [id, jsonEncode(receipt.toJson())],
      );
      return receipt;
    });
  }

  Future<List<String>> pendingOutputOperationIds() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          "SELECT operation_id FROM backup_operations WHERE invalidated=0 AND operation_id NOT LIKE 'file-output:%' AND operation_id NOT LIKE 'file-open:%'",
        )
        .get();
    final result = <String>[];
    for (final row in rows) {
      final id = row.read<String>('operation_id'),
          action = await backupOperationAction(
            row.read<String>('operation_id'),
          );
      if ((action == 'saveKey' || action == 'export') &&
          (await _outputRecord(id))!.cleanupPending)
        result.add(id);
    }
    return result;
  }

  Future<MacBackupStagingDirectory?> outputStagingDirectory(String id) async {
    _checkOpen();
    return (await _stagingFor(id, invalidated: true))?.root;
  }

  Future<BackupOutputReceipt?> latestExportOperation() async {
    _checkOpen();
    final rows = await _repository._db
        .customSelect(
          "SELECT operation_id FROM backup_operations WHERE invalidated=0 AND operation_id NOT LIKE 'file-output:%' AND operation_id NOT LIKE 'file-open:%'",
        )
        .get();
    _BackupOutputRecord? latest;
    for (final row in rows) {
      final id = row.read<String>('operation_id');
      if (await backupOperationAction(id) != 'export') continue;
      final value = (await _outputRecord(id))!;
      if (value.phase == BackupOutputPhase.succeeded &&
          (latest == null || value.version > latest.version))
        latest = value;
    }
    return latest == null ? null : BackupOutputReceipt._(latest);
  }
}
