part of 'info_storage.dart';

/// Private device facts needed to reconcile the original server command and
/// native file publication. No information body, recovery key or backup bytes.
final class DeviceBackupIntent {
  DeviceBackupIntent._(
    this.intent,
    this.outputHash,
    this.outputLength,
    Map<String, int>? outputCounts,
    Map<String, Object?>? result,
  ) : outputCounts = outputCounts == null
          ? null
          : Map.unmodifiable(outputCounts),
      result = result == null ? null : Map.unmodifiable(result);
  final BackupOwnerIntent intent;
  final String? outputHash;
  final int? outputLength;
  final Map<String, int>? outputCounts;
  final Map<String, Object?>? result;
  Map<String, Object?> _json() => {
    'format': 1,
    'command': intent.command,
    'restoreCounts': intent.restoreCounts,
    'pending': intent.pending,
    'outputHash': outputHash,
    'outputLength': outputLength,
    'outputCounts': outputCounts,
    'result': result,
  };
  @override
  String toString() => 'DeviceBackupIntent([private])';
}

/// A device-only encrypted operation journal. Native output is delegated to
/// the SAME backup publication/staging/reconciliation state machine as the
/// original Owner App. Its local operation version is not a server version.
final class DeviceBackupOperations {
  DeviceBackupOperations._(this._store);
  final DeviceFileOperations _store;
  GeneratedDatabase get _db => _store._db;
  late final InformationBackups publication = InformationBackups._device(
    _db,
    () => _store._closed,
    _verifyPrepared,
  );

  static Future<DeviceBackupOperations> open(
    String directory, {
    required String serverId,
    DatabaseKeyStore? keys,
  }) async => DeviceBackupOperations._(
    await DeviceFileOperations.open(directory, serverId: serverId, keys: keys),
  );
  Future<void> close() => _store.close();
  void _check(String id) {
    if (_store._closed) throw const StorageFailure('library_closed');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id))
      throw const StorageFailure('invalid_backup_operation');
  }

  Map<String, Object?>? _result(BackupOwnerIntent c, Object? raw) {
    if (raw == null) return null;
    final r = Map<String, Object?>.from(raw as Map);
    const keys = {
      'wireVersion',
      'operationId',
      'commandDigest',
      'action',
      'expectedVersion',
      'version',
      'resource',
      'counts',
    };
    if (r.length != keys.length ||
        !r.keys.toSet().containsAll(keys) ||
        r['wireVersion'] != 1 ||
        r['operationId'] != c.operationId ||
        r['commandDigest'] != c.digest ||
        r['action'] != c.action ||
        r['expectedVersion'] != c.expectedVersion ||
        r['version'] != c.expectedVersion + 1) {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
    final counts = r['counts'] == null
        ? null
        : (r['counts'] as Map).cast<String, int>();
    if ({'enableKey', 'cleanup'}.contains(c.action)) {
      if (r['resource'] != null || counts != null)
        throw const FormatException();
    } else {
      final resource = Map<String, Object?>.from(r['resource'] as Map);
      final selection = c.command['selection'] as Map;
      if (resource.length != 4 ||
          !resource.keys.toSet().containsAll({'id', 'name', 'version', 'kind'}))
        throw const FormatException();
      _validateRestoreResource(
        resource['id'] as String,
        resource['name'] as String,
        resource['version'] as int,
      );
      if (resource['name'] != selection['name'] ||
          resource['kind'] !=
              (c.action == 'saveKey' ? 'keyInput' : 'archiveInput') ||
          (c.action == 'restore' &&
              (resource['id'] != selection['id'] ||
                  resource['version'] != selection['version'])) ||
          (c.action == 'saveKey'
              ? counts != null
              : counts == null || !_validBackupCounts(counts)))
        throw const FormatException();
      if (c.action == 'restore' && !_sameCounts(counts!, c.restoreCounts!))
        throw const FormatException();
    }
    return Map<String, Object?>.unmodifiable(
      jsonDecode(jsonEncode(r)) as Map<String, dynamic>,
    );
  }

  bool _sameCounts(Map<String, int> a, Map<String, int> b) =>
      {...a.keys, ...b.keys}.every((k) => (a[k] ?? 0) == (b[k] ?? 0));
  DeviceBackupIntent _decode(Object? raw) {
    try {
      final v = Map<String, Object?>.from(raw as Map);
      if (v.length != 8 ||
          !v.keys.toSet().containsAll({
            'format',
            'command',
            'restoreCounts',
            'pending',
            'outputHash',
            'outputLength',
            'outputCounts',
            'result',
          }) ||
          v['format'] != 1)
        throw const FormatException();
      final command = _checkedOwnerCommand(
        Map<String, Object?>.from(v['command'] as Map),
        v['restoreCounts'] == null
            ? null
            : (v['restoreCounts'] as Map).cast<String, int>(),
        v['pending'] as bool,
      );
      final hash = v['outputHash'] as String?,
          length = v['outputLength'] as int?;
      final counts = v['outputCounts'] == null
          ? null
          : (v['outputCounts'] as Map).cast<String, int>();
      if (hash == null
          ? length != null || counts != null
          : !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
                length == null ||
                length < 1 ||
                !{'saveKey', 'export'}.contains(command.action) ||
                (command.action == 'saveKey'
                    ? length > 256 || counts == null || counts.isNotEmpty
                    : length > AttachmentBackupContainer.maxFileBytes ||
                          counts == null ||
                          !_validBackupCounts(counts)))
        throw const FormatException();
      final result = _result(command, v['result']);
      if (command.pending && result != null ||
          result != null &&
              command.action == 'export' &&
              (counts == null ||
                  !_sameCounts(
                    counts,
                    (result['counts'] as Map).cast<String, int>(),
                  )))
        throw const FormatException();
      return DeviceBackupIntent._(command, hash, length, counts, result);
    } on Object {
      throw const StorageFailure('invalid_backup_operation_receipt');
    }
  }

  Future<DeviceBackupIntent?> read(String id) async {
    _check(id);
    final rows = await _db
        .customSelect(
          'SELECT payload FROM device_backup_intents WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    final r = _decode(
      decodeProtocolObject(
        rows.single.read<String>('payload'),
        maxBytes: 131072,
      ),
    );
    if (r.intent.operationId != id)
      throw const StorageFailure('invalid_backup_operation_receipt');
    return r;
  }

  Future<List<DeviceBackupIntent>> pending() async {
    if (_store._closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect('SELECT operation_id,payload FROM device_backup_intents')
        .get();
    final result = <DeviceBackupIntent>[];
    for (final row in rows) {
      final r = _decode(
        decodeProtocolObject(row.read<String>('payload'), maxBytes: 131072),
      );
      if (r.intent.operationId != row.read<String>('operation_id'))
        throw const StorageFailure('invalid_backup_operation_receipt');
      if (r.intent.pending) result.add(r);
    }
    if (result.length > 1) throw const StorageFailure('backup_outcome_unknown');
    return List.unmodifiable(result);
  }

  Future<void> _write(DeviceBackupIntent r, {bool insert = false}) async {
    final checked = _decode(r._json());
    await _db.customStatement(
      insert
          ? 'INSERT INTO device_backup_intents(operation_id,payload) VALUES(?,?)'
          : 'UPDATE device_backup_intents SET payload=? WHERE operation_id=?',
      insert
          ? [checked.intent.operationId, jsonEncode(checked._json())]
          : [jsonEncode(checked._json()), checked.intent.operationId],
    );
  }

  Future<bool> record(
    Map<String, Object?> command, {
    Map<String, int>? restoreCounts,
  }) async {
    final c = _checkedOwnerCommand(command, restoreCounts, true);
    _check(c.operationId);
    return _db.transaction(() async {
      final old = await read(c.operationId);
      if (old != null) {
        if (old.intent.digest != c.digest ||
            !_sameCounts(old.intent.restoreCounts ?? {}, restoreCounts ?? {}))
          throw const StorageFailure('operation_conflict');
        return false;
      }
      if ((await pending()).isNotEmpty)
        throw const StorageFailure('backup_outcome_unknown');
      await _write(
        DeviceBackupIntent._(c, null, null, null, null),
        insert: true,
      );
      return true;
    });
  }

  Future<void> bindOutput(
    String id, {
    required String sha256,
    required int byteLength,
    required Map<String, int> counts,
  }) async {
    _check(id);
    await _db.transaction(() async {
      final old = await read(id);
      if (old == null || !old.intent.pending)
        throw const StorageFailure('operation_conflict');
      if (old.outputHash != null) {
        if (old.outputHash != sha256 ||
            old.outputLength != byteLength ||
            !_sameCounts(old.outputCounts!, counts))
          throw const StorageFailure('operation_conflict');
        return;
      }
      await _write(
        DeviceBackupIntent._(old.intent, sha256, byteLength, counts, null),
      );
    });
  }

  Future<Map<String, int>> _verifyPrepared(
    String id,
    BackupOutputAction action,
    String digest,
    MacBackupPublication p,
  ) async {
    final r = await read(id);
    if (r == null ||
        !r.intent.pending ||
        r.intent.action != action.name ||
        r.intent.digest != digest ||
        r.outputHash != p.digest ||
        r.outputLength != p.bytes ||
        (r.intent.command['selection'] as Map)['name'] !=
            File(p.destination).uri.pathSegments.last) {
      throw const StorageFailure('backup_changed');
    }
    MacBackupPublicationFiles.verifyPrepared(p);
    return r.outputCounts!;
  }

  Future<void> settle(String id, Map<String, Object?>? receipt) async {
    _check(id);
    await _db.transaction(() async {
      final old = await read(id);
      if (old == null) throw const StorageFailure('operation_conflict');
      final result = _result(old.intent, receipt);
      if (!old.intent.pending) {
        if (jsonEncode(old.result) != jsonEncode(result))
          throw const StorageFailure('operation_conflict');
        return;
      }
      if ({'saveKey', 'export'}.contains(old.intent.action)) {
        final native = await publication._outputRecord(id);
        if (native != null && native.digest != old.intent.digest)
          throw const StorageFailure('operation_conflict');
        if (result != null
            ? native?.phase != BackupOutputPhase.succeeded
            : native != null &&
                  native.phase != BackupOutputPhase.notPublished) {
          throw const StorageFailure('backup_outcome_unknown');
        }
      }
      final c = _checkedOwnerCommand(
        Map<String, Object?>.from(old.intent.command),
        old.intent.restoreCounts,
        false,
      );
      await _write(
        DeviceBackupIntent._(
          c,
          old.outputHash,
          old.outputLength,
          old.outputCounts,
          result,
        ),
      );
    });
  }
}
