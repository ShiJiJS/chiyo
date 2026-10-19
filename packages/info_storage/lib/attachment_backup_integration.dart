part of 'info_storage.dart';

// Owner memory only. The recovery key and selected source path never enter
// portable rows, Agent responses, or audit/history payloads.
final class _AttachmentBackupOrigin {
  const _AttachmentBackupOrigin(this.path, this.key, this.fingerprint);
  final String path, key, fingerprint;
}

extension _AttachmentBackupIntegration on InformationBackups {
  Map<String, Object?> _document(BackupContents contents) => {
    'format': InformationBackups._format,
    'version': contents.formatVersion,
    'createdAt': contents.createdAt.toIso8601String(),
    'tables': contents._tables,
    if (contents.formatVersion >= 8)
      'attachments': [for (final v in contents.attachments) v.toPrivateJson()],
  };
  BackupContents _contentsFromReader(AttachmentBackupReader reader) =>
      InformationBackups._validate({
        'format': InformationBackups._format,
        'version': reader.formatVersion,
        'createdAt': reader.createdAt.toIso8601String(),
        'tables': reader.tables,
        'attachments': [for (final v in reader.versions) v.toPrivateJson()],
      });
  String _fingerprint(BackupContents contents) => crypto.sha256
      .convert(utf8.encode(jsonEncode(_document(contents))))
      .toString();

  Future<BackupContents> _inspectAttachmentBackup(
    String path,
    String key,
  ) async {
    final reader = await AttachmentBackupContainer.openValidated(path, key);
    try {
      final raw = _contentsFromReader(reader);
      return _retain(
        BackupContents._(
          raw._tables,
          raw.createdAt,
          raw.formatVersion,
          attachments: raw.attachments,
          origin: _AttachmentBackupOrigin(path, key, _fingerprint(raw)),
        ),
        _repository._clock().toUtc(),
      );
    } finally {
      reader.close();
    }
  }

  Future<BackupContents> _restoreAttachmentBackup(
    BackupContents preview,
  ) async {
    final origin = preview._origin;
    if (origin == null) throw const StorageFailure('invalid_backup');
    final reader = await AttachmentBackupContainer.openValidated(
      origin.path,
      origin.key,
    );
    try {
      final current = _contentsFromReader(reader);
      if (_fingerprint(current) != origin.fingerprint)
        throw const StorageFailure('backup_changed');
      // Validation and all reads during installation use this same locked source.
      return await _installBackup(current, reader: reader);
    } finally {
      reader.close();
    }
  }

  Future<void> _installAttachmentBodies(
    BackupContents contents,
    AttachmentBackupReader reader,
  ) async {
    for (final v in contents.attachments) {
      Uint8List? bytes;
      if (v.available) {
        // Bounded to one <=10 MiB original; never allocate all library files.
        final builder = BytesBuilder(copy: false);
        await for (final chunk in reader.readAttachment(v.reference)) {
          builder.add(chunk);
        }
        bytes = builder.takeBytes();
        if (bytes.length != v.byteLength)
          throw const StorageFailure('attachment_integrity_failed');
      }
      await _repository._db.customStatement(
        'INSERT INTO information_attachment_versions(attachment_id,version,metadata,byte_length,body) VALUES(?,?,?,?,?)',
        [
          v.reference.attachmentId,
          v.reference.attachmentVersion,
          jsonEncode(v.toPrivateJson()),
          v.byteLength,
          bytes,
        ],
      );
    }
  }
}
