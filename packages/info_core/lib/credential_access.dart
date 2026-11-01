part of 'info_core.dart';

extension CredentialOwnerAccess on OwnerAccess {
  CredentialRepository get _vault {
    if (!serviceAvailable || _service._repository is! CredentialRepository) {
      throw const AccessFailure('service_unavailable');
    }
    return _service._repository as CredentialRepository;
  }

  List<ManagedCredential> get credentials => List.unmodifiable(
    _vault.managedCredentials.where((c) => c.deletedAt == null),
  );
  List<ManagedCredential> get recycledCredentials => List.unmodifiable(
    _vault.managedCredentials.where(
      (c) =>
          c.deletedAt != null &&
          c.purgedAt == null &&
          _service._clock().isBefore(
            c.deletedAt!.add(const Duration(days: 30)),
          ),
    ),
  );
  List<CredentialVersionInfo> credentialVersions(String id) => _vault
      .credentialMaterials
      .where(
        (m) =>
            m.credentialId == id &&
            (m.retiredAt == null ||
                _service._clock().isBefore(
                  m.retiredAt!.add(const Duration(days: 30)),
                )),
      )
      .map(CredentialVersionInfo.new)
      .toList(growable: false);
  CredentialImpact previewCredentialImpact(String id) => CredentialImpact(
    credential(id),
    informationForCredential(id).map((i) => i.id),
  );
  Future<ManagedCredential> deleteCredential(String id, int revision) =>
      _serialize(() async {
        final now = _service._clock().toUtc();
        final c = _expectCredential(id, revision).copy(
          deletedAt: now,
          enabled: false,
          invalidateUse: true,
          modifiedAt: now,
        );
        await _saveCredential(
          c,
          materials: [
            for (final m in _vault.credentialMaterials)
              m.credentialId == id ? m.retire(now) : m,
          ],
        );
        return c;
      });
  Future<ManagedCredential> restoreCredential(String id) => _serialize(
    () async {
      final c = credential(id);
      if (c.deletedAt == null) throw const AccessFailure('credential_conflict');
      final material = _retainedMaterial(id, c.version);
      return _rotateCredential(
        c,
        material.bytes,
        material.fileName,
        restore: true,
      );
    },
  );
  Future<ManagedCredential> restoreCredentialVersion(
    String id,
    int revision,
    int version,
  ) => _serialize(() async {
    final c = _expectCredential(id, revision);
    if (version == c.version) throw const AccessFailure('credential_conflict');
    final m = _retainedMaterial(id, version);
    return _rotateCredential(c, m.bytes, m.fileName, restore: true);
  });
  CredentialMaterial _retainedMaterial(String id, int version) {
    final m = _vault.credentialMaterials
        .where((m) => m.credentialId == id && m.version == version)
        .firstOrNull;
    if (m == null ||
        m.retiredAt != null &&
            !_service._clock().isBefore(
              m.retiredAt!.add(const Duration(days: 30)),
            )) {
      throw const AccessFailure('credential_material_purged');
    }
    return m;
  }

  Future<void> purgeExpiredCredentialMaterial() => _serialize(() async {
    final cutoff = _service._clock().subtract(const Duration(days: 30));
    final keep = _vault.credentialMaterials
        .where((m) => m.retiredAt == null || m.retiredAt!.isAfter(cutoff))
        .toList();
    if (keep.length != _vault.credentialMaterials.length) {
      await _vault.commitCredentials(_vault.managedCredentials, keep);
    }
  });
  Future<void> permanentlyDeleteCredential(String id, int revision) =>
      _serialize(() async {
        final old = credential(id);
        if (old.revision != revision || old.deletedAt == null) {
          throw const AccessFailure('credential_conflict');
        }
        await _saveCredential(
          old.copy(
            invalidateUse: true,
            purgedAt: _service._clock().toUtc(),
            modifiedAt: _service._clock(),
          ),
          materials: _vault.credentialMaterials
              .where((m) => m.credentialId != id)
              .toList(),
        );
      });
  ManagedCredential credential(String id) =>
      _vault.managedCredentials.where((c) => c.id == id).firstOrNull ??
      (throw const AccessFailure('credential_deleted'));
  CredentialAvailability credentialAvailability(ManagedCredential c) =>
      c.availability(_service._clock());
  List<ManagedCredential> credentialsForInformation(String itemId) =>
      credentials
          .where((c) => c.linkedItemIds.contains(itemId))
          .toList(growable: false);
  List<InformationItem> informationForCredential(String id) {
    final c = credential(id);
    return information
        .where((i) => c.linkedItemIds.contains(i.id))
        .toList(growable: false);
  }

  ManagedCredential checkCredentialEligibility(
    String id,
    int version, {
    int? useGeneration,
  }) => _service._eligibleCredential(id, version, useGeneration: useGeneration);
  Future<ManagedCredential> createFileCredential({
    required String name,
    required String publicPurpose,
    required String fileName,
    required List<int> bytes,
    String privateNote = '',
    String suggestedBinding = 'credential_file',
    DateTime? expiresAt,
  }) {
    // Copy before the first await: callers cannot mutate a submitted file.
    final copy = List<int>.of(bytes);
    return _serialize(() async {
      _validateCredentialMetadata(
        name,
        publicPurpose,
        privateNote,
        suggestedBinding,
      );
      _validateFile(fileName, copy);
      return _createCredential(
        name,
        publicPurpose,
        privateNote,
        suggestedBinding,
        CredentialForm.file,
        copy,
        fileName,
        expiresAt,
      );
    });
  }

  void _validateFile(String name, List<int> bytes) {
    if (name.isEmpty ||
        name.length > 255 ||
        name == '.' ||
        name == '..' ||
        RegExp(r'[\\/:\x00-\x1f]').hasMatch(name) ||
        bytes.isEmpty ||
        bytes.length > 1048576 ||
        bytes.any((b) => b < 0 || b > 255)) {
      throw const AccessFailure('invalid_credential_file');
    }
  }

  Future<ManagedCredential> setCredentialLinks(
    String id,
    int revision,
    List<String> itemIds,
  ) => _serialize(() async {
    if (itemIds.length > 200 ||
        itemIds.toSet().length != itemIds.length ||
        itemIds.any((id) => !information.any((i) => i.id == id))) {
      throw const AccessFailure('invalid_credential_links');
    }
    final c = _expectCredential(
      id,
      revision,
    ).copy(linkedItemIds: itemIds, modifiedAt: _service._clock().toUtc());
    await _saveCredential(c);
    return c;
  });
  Future<void> setInformationCredentialLinks(
    String itemId,
    List<String> credentialIds, {
    Map<String, int>? expectedRevisions,
  }) => _serialize(() async {
    if (!information.any((i) => i.id == itemId) ||
        credentialIds.length > 200 ||
        credentialIds.toSet().length != credentialIds.length ||
        credentialIds.any((id) => !credentials.any((c) => c.id == id))) {
      throw const AccessFailure('invalid_credential_links');
    }
    final now = _service._clock().toUtc();
    final changed = <ManagedCredential>[];
    for (final c in _vault.managedCredentials) {
      final linked = c.linkedItemIds.contains(itemId),
          selected = credentialIds.contains(c.id);
      if (linked == selected) {
        changed.add(c);
        continue;
      }
      if (expectedRevisions != null && expectedRevisions[c.id] != c.revision) {
        throw const AccessFailure('credential_conflict');
      }
      changed.add(
        c.copy(
          linkedItemIds: selected
              ? [...c.linkedItemIds, itemId]
              : c.linkedItemIds.where((id) => id != itemId),
          modifiedAt: now,
        ),
      );
    }
    await _vault.commitCredentials(changed, _vault.credentialMaterials);
  });
  Future<ManagedCredential> setCredentialEnabled(
    String id,
    int revision,
    bool enabled,
  ) => _serialize(() async {
    final c = _expectCredential(id, revision).copy(
      enabled: enabled,
      invalidateUse: true,
      modifiedAt: _service._clock().toUtc(),
    );
    await _saveCredential(c);
    return c;
  });
  Future<ManagedCredential> rotateStringCredential(
    String id,
    int revision,
    String secret,
  ) => _serialize(() async {
    if (secret.isEmpty ||
        secret.contains('\u0000') ||
        utf8.encode(secret).length > 65536) {
      throw const AccessFailure('invalid_credential_content');
    }
    final c = _expectCredential(id, revision);
    if (c.form != CredentialForm.string) {
      throw const AccessFailure('credential_form_mismatch');
    }
    return _rotateCredential(c, utf8.encode(secret), null);
  });
  Future<ManagedCredential> rotateFileCredential(
    String id,
    int revision, {
    required List<int> bytes,
    required String fileName,
  }) {
    final copy = List<int>.of(bytes);
    return _serialize(() async {
      _validateFile(fileName, copy);
      final c = _expectCredential(id, revision);
      if (c.form != CredentialForm.file) {
        throw const AccessFailure('credential_form_mismatch');
      }
      return _rotateCredential(c, copy, fileName);
    });
  }

  Future<ManagedCredential> _rotateCredential(
    ManagedCredential old,
    List<int> bytes,
    String? fileName, {
    bool restore = false,
  }) async {
    final now = _service._clock().toUtc();
    final c = old.copy(
      version: old.version + 1,
      modifiedAt: now,
      fileName: fileName,
      byteLength: bytes.length,
      invalidateUse: true,
      restore: restore,
      enabled: restore ? false : old.enabled,
      directoryId: restore ? _existingDirectory(old.directoryId) : null,
      clearDirectory: restore && _existingDirectory(old.directoryId) == null,
      tagIds: restore ? _existingTags(old.tagIds) : null,
    );
    await _saveCredential(
      c,
      materials: [
        for (final m in _vault.credentialMaterials)
          m.credentialId == old.id && m.retiredAt == null ? m.retire(now) : m,
        CredentialMaterial(
          credentialId: old.id,
          version: c.version,
          bytes: bytes,
          createdAt: now,
          fileName: fileName,
        ),
      ],
    );
    return c;
  }

  Future<ManagedCredential> createStringCredential({
    required String name,
    required String publicPurpose,
    required String secret,
    String privateNote = '',
    String suggestedBinding = 'SERVICE_TOKEN',
    DateTime? expiresAt,
  }) => _serialize(() async {
    _validateCredentialMetadata(
      name,
      publicPurpose,
      privateNote,
      suggestedBinding,
    );
    final bytes = utf8.encode(secret);
    if (secret.isEmpty || secret.contains('\u0000') || bytes.length > 65536) {
      throw const AccessFailure('invalid_credential_content');
    }
    return _createCredential(
      name,
      publicPurpose,
      privateNote,
      suggestedBinding,
      CredentialForm.string,
      bytes,
      null,
      expiresAt,
    );
  });
  void _validateCredentialMetadata(
    String name,
    String purpose,
    String note,
    String binding,
  ) {
    if (name.trim().isEmpty ||
        name.length > 60 ||
        purpose.length > 2000 ||
        note.length > 4000 ||
        [name, purpose, note].any((s) => s.contains('\u0000')) ||
        binding.isNotEmpty &&
            !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(binding)) {
      throw const AccessFailure('invalid_credential_metadata');
    }
  }

  Future<ManagedCredential> _createCredential(
    String name,
    String purpose,
    String note,
    String binding,
    CredentialForm form,
    List<int> bytes,
    String? fileName,
    DateTime? expiry,
  ) async {
    final vault = _vault, now = _service._clock().toUtc();
    final c = ManagedCredential(
      id: _service._secret(),
      name: name.trim(),
      publicPurpose: purpose,
      privateNote: note,
      form: form,
      version: 1,
      revision: 1,
      suggestedBinding: binding,
      createdAt: now,
      modifiedAt: now,
      expiresAt: expiry?.toUtc(),
      byteLength: bytes.length,
      fileName: fileName,
    );
    await vault.commitCredentials(
      [...vault.managedCredentials, c],
      [
        ...vault.credentialMaterials,
        CredentialMaterial(
          credentialId: c.id,
          version: 1,
          bytes: bytes,
          createdAt: now,
          fileName: fileName,
        ),
      ],
    );
    return c;
  }

  ManagedCredential _expectCredential(String id, int revision) {
    final c = credential(id);
    if (c.deletedAt != null) throw const AccessFailure('credential_deleted');
    if (c.revision != revision) {
      throw const AccessFailure('credential_conflict');
    }
    return c;
  }

  Future<void> _saveCredential(
    ManagedCredential c, {
    List<CredentialMaterial>? materials,
  }) => _vault.commitCredentials([
    for (final old in _vault.managedCredentials) old.id == c.id ? c : old,
  ], materials ?? _vault.credentialMaterials);
  Future<ManagedCredential> updateCredentialMetadata(
    String id,
    int revision, {
    required String name,
    required String publicPurpose,
    required String privateNote,
    required String suggestedBinding,
    required bool discoverable,
    DateTime? expiresAt,
  }) => _serialize(() async {
    _validateCredentialMetadata(
      name,
      publicPurpose,
      privateNote,
      suggestedBinding,
    );
    final c = _expectCredential(id, revision).copy(
      name: name.trim(),
      publicPurpose: publicPurpose,
      privateNote: privateNote,
      suggestedBinding: suggestedBinding,
      discoverable: discoverable,
      expiresAt: expiresAt?.toUtc(),
      clearExpiry: expiresAt == null,
      invalidateUse: credential(id).expiresAt != expiresAt?.toUtc(),
      modifiedAt: _service._clock().toUtc(),
    );
    await _saveCredential(c);
    return c;
  });
}

extension _CredentialService on InformationService {
  ManagedCredential _eligibleCredential(
    String id,
    int version, {
    int? useGeneration,
    bool requireMaterial = true,
  }) {
    final c = owner.credential(id);
    switch (c.availability(_clock())) {
      case CredentialAvailability.deleted:
        throw const AccessFailure('credential_deleted');
      case CredentialAvailability.disabled:
        throw const AccessFailure('credential_disabled');
      case CredentialAvailability.expired:
        throw const AccessFailure('credential_expired');
      case CredentialAvailability.available:
        break;
    }
    if (c.version != version ||
        useGeneration != null && c.useGeneration != useGeneration) {
      throw const AccessFailure('credential_version_changed');
    }
    if (requireMaterial) _currentCredentialMaterial(c);
    return c;
  }

  CredentialMaterial _currentCredentialMaterial(ManagedCredential c) {
    final m = (_repository as CredentialRepository).credentialMaterials
        .where(
          (m) =>
              m.credentialId == c.id &&
              m.version == c.version &&
              m.retiredAt == null,
        )
        .firstOrNull;
    if (m == null) throw const AccessFailure('credential_material_purged');
    return m;
  }
}

extension CredentialAgentAccess on AgentAccess {
  CredentialCatalogPage credentialCatalog({String? cursor, int limit = 50}) {
    if (!_service.owner.serviceAvailable) {
      throw const AccessFailure('service_unavailable');
    }
    if (limit < 1 || limit > 100) throw const AccessFailure('invalid_request');
    final source = _service._repository;
    final list = source is CredentialRepository
        ? (source as CredentialRepository).managedCredentials
              .where((c) => c.discoverable && c.deletedAt == null)
              .toList()
        : <ManagedCredential>[];
    list.sort((a, b) {
      final byName = unorm.nfc(a.name).compareTo(unorm.nfc(b.name));
      return byName == 0 ? a.id.compareTo(b.id) : byName;
    });
    var start = 0;
    if (cursor != null) {
      if (cursor.isEmpty ||
          cursor.length > 128 ||
          cursor.codeUnits.any((c) => c < 0x21 || c > 0x7e)) {
        throw const AccessFailure('invalid_cursor');
      }
      final at = list.indexWhere((c) => c.id == cursor);
      if (at < 0) throw const AccessFailure('invalid_cursor');
      start = at + 1;
    }
    final page = list.skip(start).take(limit).toList();
    return CredentialCatalogPage(
      page.map(
        (c) => {
          'credentialId': c.id,
          'name': c.name,
          'publicPurpose': c.publicPurpose,
          'form': c.form.name,
          'version': c.version,
          'availability': c.availability(_service._clock()).name,
          if (c.tagIds.isNotEmpty) 'tagIds': c.tagIds,
          if (c.tagIds.isNotEmpty)
            'tags': [
              for (final id in c.tagIds)
                for (final tag in source.tags.where((t) => t.id == id))
                  {'id': id, 'name': tag.name},
            ],
        },
      ),
      start + page.length < list.length ? page.last.id : null,
    );
  }
}
