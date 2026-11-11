part of 'info_storage.dart';

extension _CredentialSnapshotValidation on EncryptedInformationRepository {
  Future<void> _writeCredentialSnapshot(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    if (credentials.any((c) => c.account.isNotEmpty)) {
      await _requireAdmissionFormat(_credentialProposalPreviewLibraryFormat);
    }
    if (credentials.any((c) => c.template != null)) {
      await _requireAdmissionFormat(_credentialImportLibraryFormat);
    }
    await _validateCredentialClassification(credentials);
    if (credentials.any((c) => c.directoryId != null || c.tagIds.isNotEmpty)) {
      await _requireCredentialClassificationFormat();
    }
    final old = await _storedCredentials();
    String assignments(Iterable<ManagedCredential> records) => jsonEncode(
      records
          .where(
            (c) =>
                c.deletedAt == null &&
                (c.directoryId != null || c.tagIds.isNotEmpty),
          )
          .map(
            (c) => jsonEncode([c.id, c.directoryId, c.tagIds.toList()..sort()]),
          )
          .toList()
        ..sort(),
    );
    if (assignments(old) != assignments(credentials)) {
      await _db.customStatement(
        'UPDATE information_classification_state SET version=version+1 WHERE singleton=1',
      );
    }
    await _db.customStatement('DELETE FROM credential_materials');
    await _db.customStatement('DELETE FROM managed_credentials');
    for (final c in credentials) {
      await _db.customStatement(
        'INSERT INTO managed_credentials(id,payload) VALUES(?,?)',
        [c.id, jsonEncode(c.toJson())],
      );
    }
    for (final m in materials) {
      await _db.customStatement(
        'INSERT INTO credential_materials(credential_id,version,payload) VALUES(?,?,?)',
        [m.credentialId, m.version, jsonEncode(m.toStorageJson())],
      );
    }
    if ((await _db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='credential_material_snapshots'",
            )
            .get())
        .isNotEmpty) {
      await _db.customStatement(
        "DELETE FROM credential_material_snapshots WHERE credential_id NOT IN (SELECT id FROM managed_credentials WHERE json_extract(payload,'\$.purgedAt') IS NULL) OR json_extract(payload,'\$.material.retiredAt')<=?",
        [_clock().toUtc().subtract(const Duration(days: 30)).toIso8601String()],
      );
    }
  }

  Future<List<ManagedCredential>> _storedCredentials() async =>
      (await _db.customSelect('SELECT payload FROM managed_credentials').get())
          .map(
            (r) => ManagedCredential.fromJson(
              jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
            ),
          )
          .toList();

  Future<bool> _credentialClassificationFormat() async =>
      (await _db
              .customSelect(
                'SELECT version FROM library_format WHERE singleton=1',
              )
              .getSingle())
          .read<int>('version') >=
      _credentialClassificationLibraryFormat;

  Future<void> _requireCredentialClassificationFormat() async {
    if (await _credentialClassificationFormat()) return;
    await _db.customStatement(
      'UPDATE library_format SET version=? WHERE singleton=1',
      [_credentialClassificationLibraryFormat],
    );
    await _db.customStatement(
      'PRAGMA user_version = $_credentialClassificationLibraryFormat',
    );
  }

  Future<void> _validateCredentialClassification(
    Iterable<ManagedCredential> credentials,
  ) async {
    final directories =
        (await _db.customSelect('SELECT id FROM information_directories').get())
            .map((r) => r.read<String>('id'))
            .toSet();
    final tags =
        (await _db.customSelect('SELECT id FROM information_tags').get())
            .map((r) => r.read<String>('id'))
            .toSet();
    if (credentials
        .where((c) => c.deletedAt == null)
        .any(
          (c) =>
              c.directoryId != null && !directories.contains(c.directoryId) ||
              c.tagIds.any((id) => !tags.contains(id)),
        )) {
      throw const AccessFailure('invalid_credential_classification');
    }
  }

  Future<void> _guardCredentialClassificationRemoval({
    String? directoryId,
    String? tagId,
  }) async {
    final active = (await _storedCredentials()).where(
      (c) => c.deletedAt == null,
    );
    if (directoryId != null &&
        active.any((c) => c.directoryId == directoryId)) {
      throw const AccessFailure('directory_not_empty');
    }
    if (tagId != null && active.any((c) => c.tagIds.contains(tagId))) {
      throw const AccessFailure('organization_conflict');
    }
  }

  void _publishCredentialSnapshot(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) {
    _credentials
      ..clear()
      ..addAll(credentials);
    _credentialMaterials
      ..clear()
      ..addAll(materials);
  }

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
