part of 'info_storage.dart';

extension _CredentialSnapshotValidation on EncryptedInformationRepository {
  Future<void> _migrateCredentialField(CredentialFieldMigration change) async {
    if (_closed) throw const StorageFailure('library_closed');
    final before = change.previous.item,
        c = change.credential,
        m = change.material;
    if (_items[before.id]?.version != before.version ||
        change.item.id != before.id ||
        change.item.version != before.version + 1 ||
        _credentials.any((v) => v.id == c.id))
      throw const StorageFailure('credential_migration_conflict');
    _validateVault([..._credentials, c], [..._credentialMaterials, m]);
    try {
      await _writeMetadata(() async {
        await _writeItem(change.item);
        await _db.customStatement(
          'INSERT INTO managed_credentials(id,payload) VALUES(?,?)',
          [c.id, jsonEncode(c.toJson())],
        );
        await _db.customStatement(
          'INSERT INTO credential_materials(credential_id,version,payload) VALUES(?,?,?)',
          [m.credentialId, m.version, jsonEncode(m.toStorageJson())],
        );
        await _writeRevision(change.previous);
        await _writeRecycle([change.recycled], [change.fact]);
      });
      _items[before.id] = change.item;
      _credentials.add(c);
      _credentialMaterials.add(m);
      _revisions.add(change.previous);
      _recycle[change.recycled.id] = change.recycled;
      _recycleFacts.add(change.fact);
    } on Object {
      throw const StorageFailure('credential_migration_failed');
    }
  }

  void _validateVault(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) {
    final ids = <String>{}, versions = <String>{};
    for (final c in credentials) {
      if (!ids.add(c.id) ||
          c.version < 1 ||
          c.revision < 1 ||
          c.useGeneration < 1) {
        throw const StorageFailure('invalid_credential_snapshot');
      }
    }
    for (final m in materials) {
      final previous = _credentialMaterials
          .where(
            (old) =>
                old.credentialId == m.credentialId && old.version == m.version,
          )
          .firstOrNull;
      if (previous != null &&
          (previous.bytes.length != m.bytes.length ||
              Iterable<int>.generate(
                previous.bytes.length,
              ).any((i) => previous.bytes[i] != m.bytes[i]) ||
              previous.fileName != m.fileName ||
              !previous.createdAt.isAtSameMomentAs(m.createdAt) ||
              previous.retiredAt != null &&
                  previous.retiredAt != m.retiredAt)) {
        throw const StorageFailure('credential_version_immutable');
      }
      final c = credentials.where((c) => c.id == m.credentialId).firstOrNull;
      if (c == null ||
          !versions.add('${m.credentialId}:${m.version}') ||
          m.version < 1 ||
          m.version > c.version ||
          m.bytes.isEmpty ||
          m.bytes.length > (c.form == CredentialForm.file ? 1048576 : 65536) ||
          m.bytes.any((b) => b < 0 || b > 255)) {
        throw const StorageFailure('invalid_credential_snapshot');
      }
    }
    for (final c in credentials.where((c) => c.deletedAt == null)) {
      if (!materials.any(
        (m) =>
            m.credentialId == c.id &&
            m.version == c.version &&
            m.retiredAt == null,
      )) {
        throw const StorageFailure('invalid_credential_snapshot');
      }
    }
  }
}
