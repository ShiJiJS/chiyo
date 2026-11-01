part of 'info_storage.dart';

// A distinct typed payload in the existing machine-local operation journal.
// Sharing IDs makes cross-kind reuse fail closed. Existing backup exclusion and
// successful-restore invalidation apply to every row without a schema change.
extension _CredentialRecordStorage on EncryptedInformationRepository {
  Future<CredentialRecordReceipt?> _credentialRecordReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM information_record_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0)
      throw const AccessFailure('library_changed');
    try {
      final value = CredentialRecordReceipt.fromJson(
        jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
      );
      if (value.operationId != id) throw const FormatException();
      return value;
    } on Object {
      // Includes a different command kind occupying this shared operation ID.
      throw const StorageFailure('invalid_operation_receipt');
    }
  }

  Future<void> _commitCredentialRecord(CredentialRecordChange change) async {
    if (_closed) throw const StorageFailure('library_closed');
    final receipt = change.receipt;
    try {
      change.validate();
      await _writeMetadata(() async {
        final before =
            (await _db
                    .customSelect('SELECT payload FROM managed_credentials')
                    .get())
                .map(
                  (r) => ManagedCredential.fromJson(
                    jsonDecode(r.read<String>('payload'))
                        as Map<String, dynamic>,
                  ),
                )
                .toList();
        final materials =
            (await _db
                    .customSelect('SELECT payload FROM credential_materials')
                    .get())
                .map(
                  (r) => CredentialMaterial.fromStorageJson(
                    jsonDecode(r.read<String>('payload'))
                        as Map<String, dynamic>,
                  ),
                )
                .toList();
        if (credentialVaultDigest(before, materials) != change.previousDigest) {
          throw const AccessFailure('credential_conflict');
        }
        _validateCredentialRecordChange(change, before, materials);
        _validateVault(change.credentials, change.materials);
        await _writeCredentialSnapshot(change.credentials, change.materials);
        await _db.customStatement(
          'INSERT INTO information_record_operations(operation_id,payload) VALUES(?,?)',
          [receipt.operationId, jsonEncode(receipt.toJson())],
        );
      }, validate: change.validate);
      _publishCredentialSnapshot(change.credentials, change.materials);
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('credential_save_failed');
    }
  }

  void _validateCredentialRecordChange(
    CredentialRecordChange change,
    List<ManagedCredential> before,
    List<CredentialMaterial> materials,
  ) {
    final r = change.receipt;
    final old = before.where((c) => c.id == r.credentialId).firstOrNull;
    final matches = change.credentials
        .where((c) => c.id == r.credentialId)
        .toList();
    final create = r.action == CredentialRecordAction.create;
    final replace = r.action == CredentialRecordAction.replaceMaterial;
    bool same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
    if (matches.length != 1 ||
        (create ? old != null : old == null) ||
        change.credentials.length != before.length + (create ? 1 : 0)) {
      throw const StorageFailure('invalid_credential_change');
    }
    final current = matches.single;
    if (!create) {
      if (r.action == CredentialRecordAction.setEnabled) {
        final expected = old!.copy(
          enabled: current.enabled,
          invalidateUse: true,
          modifiedAt: current.modifiedAt,
        );
        if (!same(current.toJson(), expected.toJson())) {
          throw const StorageFailure('invalid_credential_change');
        }
      } else if (current.enabled != old!.enabled ||
          (!replace &&
              (current.fileName != old.fileName ||
                  current.byteLength != old.byteLength))) {
        throw const StorageFailure('invalid_credential_change');
      }
    }
    if (current.revision != r.revision ||
        current.version != r.materialVersion ||
        current.useGeneration != r.useGeneration ||
        current.deletedAt != null ||
        current.purgedAt != null ||
        (!create &&
            (old!.revision != r.baseRevision ||
                old.version != r.baseMaterialVersion ||
                old.form != current.form ||
                old.createdAt != current.createdAt ||
                current.useGeneration !=
                    old.useGeneration +
                        ((replace ||
                                r.action == CredentialRecordAction.setEnabled ||
                                old.expiresAt != current.expiresAt)
                            ? 1
                            : 0))) ||
        (create && (current.useGeneration != 1 || !current.enabled))) {
      throw const StorageFailure('invalid_credential_change');
    }
    for (final c in before.where((c) => c.id != r.credentialId)) {
      final next = change.credentials.where((v) => v.id == c.id).firstOrNull;
      if (next == null || !same(next.toJson(), c.toJson()))
        throw const StorageFailure('invalid_credential_change');
    }
    if (change.materials.length !=
        materials.length + ((create || replace) ? 1 : 0)) {
      throw const StorageFailure('invalid_credential_change');
    }
    for (final m in materials) {
      final next = change.materials
          .where(
            (v) => v.credentialId == m.credentialId && v.version == m.version,
          )
          .firstOrNull;
      final expected =
          replace && m.credentialId == r.credentialId && m.retiredAt == null
          ? m.retire(current.modifiedAt)
          : m;
      if (next == null ||
          !same(next.toStorageJson(), expected.toStorageJson())) {
        throw const StorageFailure('invalid_credential_change');
      }
    }
    if (create || replace) {
      final head = change.materials
          .where(
            (v) =>
                v.credentialId == r.credentialId &&
                v.version == r.materialVersion,
          )
          .single;
      if (head.fileName != current.fileName ||
          head.bytes.length != current.byteLength ||
          head.createdAt != current.modifiedAt ||
          head.retiredAt != null) {
        throw const StorageFailure('invalid_credential_change');
      }
    }
  }
}
