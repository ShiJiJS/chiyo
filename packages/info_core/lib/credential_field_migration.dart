part of 'info_core.dart';

class CredentialMigrationPreview {
  const CredentialMigrationPreview(
    this.item,
    this.field,
    this.activeGrantCount,
    this.revisionCount,
    this.recycleCopyCount,
  );
  final InformationItem item;
  final InformationField field;
  final int activeGrantCount, revisionCount, recycleCopyCount;
  String get credentialName => _credentialMigrationName(field.name);
}

String _credentialMigrationName(String value) {
  var name = '';
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    if (name.length + character.length > 60) break;
    name += character;
  }
  return name;
}

/// Desktop-only atomic write. Secret bytes never cross the agent transport.
abstract interface class CredentialFieldMigrationRepository {
  Future<void> commitCredentialFieldMigration(CredentialFieldMigration change);
}

class CredentialFieldMigration {
  const CredentialFieldMigration({
    required this.item,
    required this.previous,
    required this.credential,
    required this.material,
    required this.recycled,
    required this.fact,
  });
  final InformationItem item;
  final InformationRevision previous;
  final ManagedCredential credential;
  final CredentialMaterial material;
  final RecycleEntry recycled;
  final RecycleFact fact;
}

extension CredentialFieldMigrationOwner on OwnerAccess {
  CredentialMigrationPreview previewCredentialMigration(
    FieldRef ref,
    int expectedVersion,
  ) {
    if (!serviceAvailable ||
        _service._repository is! CredentialFieldMigrationRepository) {
      throw const AccessFailure('service_unavailable');
    }
    final item = information.where((i) => i.id == ref.itemId).firstOrNull;
    if (item == null || item.version != expectedVersion) {
      throw const AccessFailure('proposal_conflict');
    }
    final field = item.fields.where((f) => f.id == ref.fieldId).firstOrNull;
    if (field == null) throw const AccessFailure('invalid_information');
    if (field.kind == FieldKind.file) {
      throw const AccessFailure('unsupported_file_write');
    }
    return CredentialMigrationPreview(
      item,
      field,
      _service._requests.values.where((r) => _service._canRead(r, ref)).length,
      informationRevisions
          .where(
            (r) =>
                r.item.id == ref.itemId &&
                r.item.fields.any((f) => f.id == ref.fieldId),
          )
          .length,
      recycleEntries
          .where(
            (r) =>
                r.itemId == ref.itemId &&
                r.snapshot?.fields.any((f) => f.id == ref.fieldId) == true,
          )
          .length,
    );
  }

  Future<ManagedCredential> migrateFieldToCredential(
    FieldRef ref,
    int expectedVersion,
  ) => _serialize(() async {
    final preview = previewCredentialMigration(ref, expectedVersion);
    final before = preview.item, field = preview.field;
    final bytes = utf8.encode(field.value);
    if (bytes.isEmpty ||
        bytes.length > 65536 ||
        field.value.contains('\u0000')) {
      throw const AccessFailure('invalid_credential_content');
    }
    final now = _service._clock().toUtc();
    final name = preview.credentialName;
    _validateCredentialMetadata(name, field.description, '', 'SERVICE_TOKEN');
    final credential = ManagedCredential(
      id: _service._secret(),
      name: name,
      publicPurpose: field.description,
      privateNote: '',
      form: CredentialForm.string,
      version: 1,
      revision: 1,
      suggestedBinding: 'SERVICE_TOKEN',
      createdAt: now,
      modifiedAt: now,
      byteLength: bytes.length,
      linkedItemIds: [before.id],
    );
    final after = InformationItem(
      before.id,
      before.name,
      before.description,
      before.version + 1,
      before.fields.where((f) => f.id != ref.fieldId).toList(),
      directoryId: before.directoryId,
      tagIds: before.tagIds,
      layout: before.layout,
      createdAt: before.createdAt,
      modifiedAt: now,
    );
    final recycled = _recycle(before, after);
    await (_service._repository as CredentialFieldMigrationRepository)
        .commitCredentialFieldMigration(
          CredentialFieldMigration(
            item: after,
            previous: InformationRevision(before, now),
            credential: credential,
            material: CredentialMaterial(
              credentialId: credential.id,
              version: 1,
              bytes: bytes,
              createdAt: now,
            ),
            recycled: recycled,
            fact: _fact(recycled, RecycleFactKind.deleted, after.version),
          ),
        );
    // Only after commit. The existing deletion invalidation is permanent for
    // this grant; explicit recycle restore already gives removed fields new IDs.
    _invalidateRemoved(before, after);
    return credential;
  });
}
