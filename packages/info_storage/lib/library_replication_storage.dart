part of 'info_storage.dart';

/// An encrypted initial transfer. Its independent key belongs to owner-private
/// transfer state and is excluded from the source database and receipts.
final class PreparedLibraryTransfer {
  PreparedLibraryTransfer._(this.transfer, this.transferKey);
  final LibraryInitialTransfer transfer;
  final String transferKey;
}

/// Owner-only content replication using the existing portable validators and
/// chunked encrypted container. The caller holds Owner's snapshot/write guard.
final class LibraryReplication {
  LibraryReplication(this.repository);
  final EncryptedInformationRepository repository;
  InformationBackups get _backups => repository.backups;

  String _id() => base64Url
      .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Future<LibraryReplicaIdentity> identity() async {
    if (repository._closed) throw const StorageFailure('library_closed');
    // Format56 follows the existing server-runtime storage boundary even on a
    // local host. No active sessions are created by this storage initialization.
    await repository._openServerState();
    return repository._db.transaction(() async {
      await repository._db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_replica_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),payload TEXT NOT NULL)',
      );
      await repository._db.customStatement(
        'CREATE TABLE IF NOT EXISTS library_replica_receipts(operation_id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
      );
      await repository._requireAdmissionFormat(_libraryReplicationFormat);
      final rows = await repository._db
          .customSelect(
            'SELECT payload FROM library_replica_state WHERE singleton=1',
          )
          .get();
      if (rows.isNotEmpty)
        return LibraryReplicaIdentity.fromJson(
          decodeProtocolObject(rows.single.read<String>('payload')),
        );
      final identity = LibraryReplicaIdentity(
        libraryId: _id(),
        replicaId: _id(),
      );
      await _saveIdentity(identity);
      return identity;
    });
  }

  Future<void> _saveIdentity(
    LibraryReplicaIdentity identity,
  ) => repository._db.customStatement(
    'INSERT INTO library_replica_state(singleton,payload) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET payload=excluded.payload',
    [jsonEncode(identity.toJson())],
  );

  Future<bool> empty() => _backups.recipientEmpty();

  Future<PreparedLibraryTransfer> exportInitial(String path) async {
    final source = await identity();
    final key =
        'aim-recovery-v1:${base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256)))}';
    late String snapshotId;
    late int format;
    await repository._db.transaction(() async {
      final document = await _backups._rawSnapshotDocument();
      final tables = Map<String, List<Map<String, Object?>>>.from(
        document['tables'] as Map,
      );
      tables['settings'] = [];
      format = max(8, document['version'] as int);
      tables.putIfAbsent('information_file_fields', () => []);
      final portable = {
        ...document,
        'version': format,
        'tables': tables,
        'attachments': document['attachments'] ?? <Object?>[],
      };
      final contents = InformationBackups._validate(portable);
      snapshotId = crypto.sha256
          .convert(
            utf8.encode(
              jsonEncode(_backups._document(contents)..remove('createdAt')),
            ),
          )
          .toString();
      await AttachmentBackupContainer.write(
        path: path,
        recoveryKey: key,
        createdAt: contents.createdAt,
        tables: contents._tables,
        formatVersion: format,
        attachments: [
          for (final version in contents.attachments)
            AttachmentBackupSource(
              version,
              read: version.available
                  ? (offset, length) => repository._readAttachmentChunk(
                      version.reference,
                      offset,
                      length,
                    )
                  : null,
            ),
        ],
      );
    });
    return PreparedLibraryTransfer._(
      LibraryInitialTransfer(
        libraryId: source.libraryId,
        snapshotId: snapshotId,
        archiveDigest: await _backups._restoreArchiveDigest(path),
        byteLength: await File(path).length(),
        contentFormat: format,
      ),
      key,
    );
  }

  Future<LibraryInitialReceipt?> receipt(
    String operationId,
    LibraryInitialTransfer transfer,
  ) async {
    final previous = await lookupReceipt(operationId);
    if (previous == null) return null;
    if (jsonEncode(previous.transfer.toJson()) != jsonEncode(transfer.toJson()))
      throw const StorageFailure('sync_operation_conflict');
    return previous;
  }

  Future<LibraryInitialReceipt?> lookupReceipt(String operationId) async {
    replicaOperationId(operationId);
    await identity();
    final rows = await repository._db
        .customSelect(
          'SELECT payload FROM library_replica_receipts WHERE operation_id=?',
          variables: [Variable(operationId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final previous = LibraryInitialReceipt.fromJson(
      decodeProtocolObject(rows.single.read<String>('payload')),
    );
    return previous;
  }

  Future<LibraryInitialReceipt> installInitial({
    required String path,
    required String transferKey,
    required String operationId,
    required LibraryInitialTransfer transfer,
  }) async {
    final previous = await receipt(operationId, transfer);
    if (previous != null) return previous;
    final target = await identity();
    if (!await empty()) throw const StorageFailure('recipient_not_empty');
    if (await File(path).length() != transfer.byteLength ||
        await _backups._restoreArchiveDigest(path) != transfer.archiveDigest)
      throw const StorageFailure('sync_integrity_failed');
    final reader = await AttachmentBackupContainer.openValidated(
      path,
      transferKey,
    );
    try {
      final contents = _backups._contentsFromReader(reader);
      if (contents.formatVersion != transfer.contentFormat ||
          contents._tables['settings']!.isNotEmpty)
        throw const StorageFailure('unsupported_sync_format');
      final document = _backups._document(contents)..remove('createdAt');
      final hash = crypto.sha256
          .convert(utf8.encode(jsonEncode(document)))
          .toString();
      if (hash != transfer.snapshotId)
        throw const StorageFailure('sync_integrity_failed');
      final receipt = LibraryInitialReceipt(
        operationId: operationId,
        identity: LibraryReplicaIdentity(
          libraryId: transfer.libraryId,
          replicaId: target.replicaId,
        ),
        transfer: transfer,
      );
      await _backups._installBackup(
        contents,
        reader: reader,
        preserveHistory: true,
        preserveSettings: true,
        commitReplication: () async {
          await _saveIdentity(receipt.identity);
          await repository._db.customStatement(
            'INSERT INTO library_replica_receipts(operation_id,payload) VALUES(?,?)',
            [operationId, jsonEncode(receipt.toJson())],
          );
        },
      );
      return receipt;
    } finally {
      reader.close();
    }
  }
}
