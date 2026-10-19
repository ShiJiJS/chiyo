part of 'info_storage.dart';

InformationFileDelivery _deliveryArchive(Map<String, Object?> row) {
  final payload = row['payload'];
  if (payload is! String) throw const StorageFailure('invalid_backup');
  return InformationFileDelivery.fromArchiveJson(decodeProtocolObject(payload));
}

List<InformationFileDelivery> _validateBackupFileDeliveries(
  Map<String, List<Map<String, Object?>>> tables,
  List<InformationAttachmentVersion> versions,
) {
  final available = {for (final v in versions) v.reference: v};
  final ids = <String>{};
  final result = <InformationFileDelivery>[];
  for (final row
      in tables['information_deliveries'] ?? <Map<String, Object?>>[]) {
    final record = _deliveryArchive(row);
    final v = available[record.attachment];
    if (record.id != row['id'] ||
        !ids.add(record.id) ||
        v == null ||
        v.originalName != record.fileName ||
        v.mediaType != record.mediaType ||
        v.byteLength != record.byteLength ||
        v.sha256 != record.sha256) {
      throw const StorageFailure('invalid_backup');
    }
    result.add(record);
  }
  return List.unmodifiable(result);
}

Map<String, Object?> _deliveryImmutable(InformationFileDelivery r) {
  final json = {
    ...r.toArchiveJson(),
    'runtime': r.runtime,
    'sessionBinding': r.sessionBinding,
  };
  for (final k in const [
    'state',
    'targetState',
    'reason',
    'cleanupError',
    'lease',
    'finishedAt',
  ]) {
    json.remove(k);
  }
  return json;
}

void _validateDeliveryTransition(
  InformationFileDelivery before,
  InformationFileDelivery after,
) {
  if (jsonEncode(_deliveryImmutable(before)) !=
      jsonEncode(_deliveryImmutable(after)))
    throw const StorageFailure('delivery_conflict');
  if (InformationFileDelivery.terminals.contains(before.state)) {
    if (jsonEncode(before.toArchiveJson()) != jsonEncode(after.toArchiveJson()))
      throw const StorageFailure('delivery_conflict');
    return;
  }
  if (before.state == 'ready' && after.state == 'preparing' ||
      before.state == 'cleanup_pending' &&
          !{'cleanup_pending', before.targetState}.contains(after.state) ||
      before.lease != null &&
          after.lease != null &&
          jsonEncode(before.lease!.toPrivateJson()) !=
              jsonEncode(after.lease!.toPrivateJson()) ||
      before.lease == null &&
          before.state != 'preparing' &&
          after.lease != null)
    throw const StorageFailure('delivery_conflict');
}

extension _EncryptedFileDeliveries on EncryptedInformationRepository {
  Future<void> _validateDeliveryOriginal(
    InformationFileDelivery record, {
    Map<InformationAttachmentRef, InformationAttachmentVersion>? versions,
  }) async {
    final v = versions == null
        ? await _attachmentVersion(record.attachment)
        : versions[record.attachment];
    if (v == null ||
        v.originalName != record.fileName ||
        v.mediaType != record.mediaType ||
        v.byteLength != record.byteLength ||
        v.sha256 != record.sha256) {
      throw const StorageFailure('attachment_integrity_failed');
    }
  }

  Future<void> _loadFileDeliveries() async {
    final rows = await _db
        .customSelect(
          'SELECT id,session_binding,operation_id,payload FROM information_deliveries ORDER BY rowid LIMIT 10001',
        )
        .get();
    if (rows.length > 10000) throw const StorageFailure('delivery_capacity');
    final records = <String, InformationFileDelivery>{};
    final versions = {
      for (final v in await _allAttachmentVersions()) v.reference: v,
    };
    for (final row in rows) {
      final r = InformationFileDelivery.fromPrivateJson(
        decodeProtocolObject(row.read<String>('payload')),
      );
      if (r.id != row.read<String>('id') ||
          r.sessionBinding != row.readNullable<String>('session_binding') ||
          r.operationId != row.read<String>('operation_id')) {
        throw const StorageFailure('delivery_conflict');
      }
      await _validateDeliveryOriginal(r, versions: versions);
      records[r.id] = r;
    }
    _fileDeliveries
      ..clear()
      ..addAll(records);
  }

  Future<void> _saveFileDelivery(InformationFileDelivery record) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        final rows = await _db
            .customSelect(
              'SELECT payload FROM information_deliveries WHERE id=?',
              variables: [Variable(record.id)],
            )
            .get();
        if (rows.isNotEmpty) {
          final before = InformationFileDelivery.fromPrivateJson(
            decodeProtocolObject(rows.single.read<String>('payload')),
          );
          _validateDeliveryTransition(before, record);
        }
        await _validateDeliveryOriginal(record);
        await _db.customStatement(
          'INSERT INTO information_deliveries(id,session_binding,operation_id,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
          [
            record.id,
            record.sessionBinding,
            record.operationId,
            jsonEncode(record.toPrivateJson()),
          ],
        );
        await _checkAttachmentBackupBudget();
      });
      _fileDeliveries[record.id] = record;
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('delivery_save_failed');
    }
  }

  Future<void> _pruneFileDeliveries(Set<String> ids) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        for (final id in ids) {
          final rows = await _db
              .customSelect(
                'SELECT payload FROM information_deliveries WHERE id=?',
                variables: [Variable(id)],
              )
              .get();
          if (rows.isEmpty) continue;
          final record = InformationFileDelivery.fromPrivateJson(
            decodeProtocolObject(rows.single.read<String>('payload')),
          );
          if (record.holdsCopy ||
              record.runtime &&
                  !InformationFileDelivery.terminals.contains(record.state))
            throw const StorageFailure('delivery_conflict');
          await _db.customStatement(
            'DELETE FROM information_deliveries WHERE id=?',
            [id],
          );
        }
      });
      _fileDeliveries.removeWhere((id, _) => ids.contains(id));
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('delivery_cleanup_failed');
    }
  }
}
