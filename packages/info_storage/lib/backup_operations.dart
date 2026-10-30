part of 'info_storage.dart';

/// Machine-local acknowledgement of recovery-key creation, never the key.
/// It is not portable backup content or an Agent capability.
final class BackupKeyOperationReceipt {
  const BackupKeyOperationReceipt._({
    required this.operationId,
    required this.commandDigest,
    required this.expectedVersion,
    required this.version,
  });
  final String operationId, commandDigest;
  final int expectedVersion, version;
  Map<String, Object?> toJson() => {
    'format': 1,
    'action': 'enableKey',
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'version': version,
  };
}

extension BackupKeyOperations on InformationBackups {
  void _validateKeyOperation(String id, String digest, int expectedVersion) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        expectedVersion < 1) {
      throw const StorageFailure('invalid_backup_operation');
    }
  }

  Future<int> operationVersion() async {
    _checkOpen();
    final row = await _repository._db
        .customSelect(
          'SELECT version FROM backup_operation_state WHERE singleton=1',
        )
        .getSingle();
    return row.read<int>('version');
  }

  Future<void> _advanceOperationVersion() => _repository._db.customStatement(
    'UPDATE backup_operation_state SET version=version+1 WHERE singleton=1',
  );

  /// Null means this exact operation was not committed. A restored library
  /// keeps invalidation tombstones and must never report those as unsubmitted.
  Future<BackupKeyOperationReceipt?> recoveryKeyOperationReceipt(
    String id,
  ) async {
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
      final value =
          jsonDecode(rows.single.read<String>('payload'))
              as Map<String, dynamic>;
      if (value.length != 6 ||
          value['format'] != 1 ||
          value['action'] != 'enableKey' ||
          value['operationId'] != id ||
          value['version'] is! int ||
          value['expectedVersion'] is! int ||
          value['commandDigest'] is! String) {
        throw const FormatException();
      }
      _validateKeyOperation(
        id,
        value['commandDigest'] as String,
        value['expectedVersion'] as int,
      );
      if (value['version'] != (value['expectedVersion'] as int) + 1) {
        throw const FormatException();
      }
      return BackupKeyOperationReceipt._(
        operationId: id,
        commandDigest: value['commandDigest'] as String,
        expectedVersion: value['expectedVersion'] as int,
        version: value['version'] as int,
      );
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  /// Recovery-key creation, version advancement and acknowledgement share one
  /// SQLCipher transaction. A lost response is reconciled by operation ID;
  /// repeating the exact intent returns its original receipt, never a new key.
  Future<BackupKeyOperationReceipt> enableWithReceipt({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
  }) async {
    _checkOpen();
    _validateKeyOperation(operationId, commandDigest, expectedVersion);
    try {
      return await _repository._db.transaction(() async {
        final previous = await recoveryKeyOperationReceipt(operationId);
        if (previous != null) {
          if (previous.commandDigest != commandDigest ||
              previous.expectedVersion != expectedVersion) {
            throw const StorageFailure('operation_conflict');
          }
          return previous;
        }
        if (await operationVersion() != expectedVersion) {
          throw const StorageFailure('backup_version_conflict');
        }
        if (await recoveryKey() == null) {
          await enable(); // Existing method advances the version when creating.
        } else {
          await _advanceOperationVersion();
        }
        final receipt = BackupKeyOperationReceipt._(
          operationId: operationId,
          commandDigest: commandDigest,
          expectedVersion: expectedVersion,
          version: await operationVersion(),
        );
        await _repository._db.customStatement(
          'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
          [operationId, jsonEncode(receipt.toJson())],
        );
        return receipt;
      });
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('backup_operation_failed');
    }
  }
}
