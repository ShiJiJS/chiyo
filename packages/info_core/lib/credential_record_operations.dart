part of 'info_core.dart';

enum CredentialRecordAction { create, edit, replaceMaterial, setEnabled }

/// Trusted Owner input. Material may enter this boundary but never a workspace
/// record, receipt or Agent response. Copy bytes before the first await.
final class CredentialRecordInput {
  CredentialRecordInput({
    required this.action,
    required this.commandDigest,
    this.credentialId,
    this.expectedRevision,
    this.expectedMaterialVersion,
    this.form,
    this.name,
    this.publicPurpose,
    this.privateNote,
    this.suggestedBinding,
    Iterable<int>? material,
    this.fileName,
    this.enabled,
    this.discoverable,
    this.updateExpiry = false,
    this.expiresAt,
    Iterable<String>? linkedItemIds,
  }) : material = material == null ? null : List.unmodifiable(material),
       linkedItemIds = linkedItemIds == null
           ? null
           : List.unmodifiable(linkedItemIds);
  final CredentialRecordAction action;
  final String commandDigest;
  final String? credentialId,
      name,
      publicPurpose,
      privateNote,
      suggestedBinding,
      fileName;
  final int? expectedRevision, expectedMaterialVersion;
  final CredentialForm? form;
  final List<int>? material;
  final List<String>? linkedItemIds;
  final bool? enabled, discoverable;
  final bool updateExpiry;
  final DateTime? expiresAt;
  String get _hash => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'action': action.name,
            'commandDigest': commandDigest,
            'credentialId': credentialId,
            'expectedRevision': expectedRevision,
            'expectedMaterialVersion': expectedMaterialVersion,
            'form': form?.name,
            'name': name?.trim(),
            'publicPurpose': publicPurpose,
            'privateNote': privateNote,
            'suggestedBinding': suggestedBinding,
            'material': material == null ? null : base64Encode(material!),
            'fileName': fileName,
            'enabled': enabled,
            'discoverable': discoverable,
            'updateExpiry': updateExpiry,
            'expiresAt': expiresAt?.toUtc().toIso8601String(),
            'linkedItemIds': linkedItemIds == null
                ? null
                : (List.of(linkedItemIds!)..sort()),
          }),
        ),
      )
      .toString();
}

/// Machine-local commit facts only. Never a retained vault/material snapshot.
final class CredentialRecordReceipt {
  CredentialRecordReceipt({
    required this.operationId,
    required this.action,
    required this.inputHash,
    required this.commandDigest,
    required this.credentialId,
    required this.baseRevision,
    required this.baseMaterialVersion,
    required this.revision,
    required this.materialVersion,
    required this.useGeneration,
  }) {
    final create = action == CredentialRecordAction.create;
    if (!_credentialOperationId(operationId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(inputHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(commandDigest) ||
        credentialId.isEmpty ||
        credentialId.length > 200 ||
        credentialId.codeUnits.any((c) => c < 33 || c > 126) ||
        useGeneration < 1 ||
        (create && useGeneration != 1) ||
        (create
            ? baseRevision != null ||
                  baseMaterialVersion != null ||
                  revision != 1 ||
                  materialVersion != 1
            : baseRevision == null ||
                  baseMaterialVersion == null ||
                  baseRevision! < 1 ||
                  baseMaterialVersion! < 1 ||
                  revision != baseRevision! + 1 ||
                  materialVersion !=
                      baseMaterialVersion! +
                          (action == CredentialRecordAction.replaceMaterial
                              ? 1
                              : 0))) {
      throw const FormatException('Invalid credential record receipt');
    }
  }
  final String operationId, inputHash, commandDigest, credentialId;
  final CredentialRecordAction action;
  final int? baseRevision, baseMaterialVersion;
  final int revision, materialVersion, useGeneration;
  Map<String, Object?> toJson() => {
    'format': 1,
    'type': 'credentialRecord',
    'operationId': operationId,
    'action': action.name,
    'inputHash': inputHash,
    'commandDigest': commandDigest,
    'credentialId': credentialId,
    'baseRevision': baseRevision,
    'baseMaterialVersion': baseMaterialVersion,
    'revision': revision,
    'materialVersion': materialVersion,
    'useGeneration': useGeneration,
  };
  factory CredentialRecordReceipt.fromJson(Map<String, dynamic> value) {
    if (value.length != 12 ||
        value['format'] != 1 ||
        value['type'] != 'credentialRecord' ||
        value['operationId'] is! String ||
        value['action'] is! String ||
        !CredentialRecordAction.values.any((v) => v.name == value['action']) ||
        value['inputHash'] is! String ||
        value['commandDigest'] is! String ||
        value['credentialId'] is! String ||
        value['revision'] is! int ||
        value['materialVersion'] is! int ||
        value['useGeneration'] is! int ||
        (value['baseRevision'] != null && value['baseRevision'] is! int) ||
        (value['baseMaterialVersion'] != null &&
            value['baseMaterialVersion'] is! int)) {
      throw const FormatException('Invalid credential record receipt');
    }
    return CredentialRecordReceipt(
      operationId: value['operationId'] as String,
      action: CredentialRecordAction.values.byName(value['action'] as String),
      inputHash: value['inputHash'] as String,
      commandDigest: value['commandDigest'] as String,
      credentialId: value['credentialId'] as String,
      baseRevision: value['baseRevision'] as int?,
      baseMaterialVersion: value['baseMaterialVersion'] as int?,
      revision: value['revision'] as int,
      materialVersion: value['materialVersion'] as int,
      useGeneration: value['useGeneration'] as int,
    );
  }
}

bool _credentialOperationId(String id) =>
    RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id);

/// Private CAS digest for a complete vault snapshot, never persisted or exposed.
String credentialVaultDigest(
  Iterable<ManagedCredential> credentials,
  Iterable<CredentialMaterial> materials,
) {
  final records = credentials.map((c) => jsonEncode(c.toJson())).toList()
    ..sort();
  final values = materials.map((m) => jsonEncode(m.toStorageJson())).toList()
    ..sort();
  return sha256.convert(utf8.encode(jsonEncode([records, values]))).toString();
}

final class CredentialRecordChange {
  CredentialRecordChange({
    required this.receipt,
    required this.previousDigest,
    required Iterable<ManagedCredential> credentials,
    required Iterable<CredentialMaterial> materials,
    required this.validate,
  }) : credentials = List.unmodifiable(credentials),
       materials = List.unmodifiable(materials);
  final CredentialRecordReceipt receipt;
  final String previousDigest;
  final List<ManagedCredential> credentials;
  final List<CredentialMaterial> materials;
  final void Function() validate;
}

abstract interface class CredentialRecordRepository {
  /// Null means confirmed absence. Invalidated, malformed or other-kind
  /// receipts occupying this ID must throw rather than masquerade as absence.
  Future<CredentialRecordReceipt?> credentialRecordReceipt(String operationId);

  /// All vault bytes and the receipt commit atomically. Revalidate at the last
  /// transaction boundary; never publish a cache snapshot before commitment.
  Future<void> commitCredentialRecord(CredentialRecordChange change);
}

extension OwnerCredentialRecords on OwnerAccess {
  bool get credentialRecordOperationsSupported =>
      serviceAvailable && _service._repository is CredentialRecordRepository;
  CredentialRecordRepository get _credentialRecords =>
      switch (_service._repository) {
        final CredentialRecordRepository r => r,
        _ => throw const AccessFailure('unsupported_capability'),
      };
  Future<CredentialRecordReceipt?> credentialRecordReceipt(String id) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        if (!_credentialOperationId(id)) {
          throw const AccessFailure('invalid_credential_operation');
        }
        return _credentialRecords.credentialRecordReceipt(id);
      });

  Future<CredentialRecordReceipt> saveCredentialRecord(
    String id,
    CredentialRecordInput input,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (!_credentialOperationId(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(input.commandDigest)) {
      throw const AccessFailure('invalid_credential_operation');
    }
    final generation = _service._libraryGeneration;
    void check() {
      if (!serviceAvailable || generation != _service._libraryGeneration) {
        throw const AccessFailure('library_changed');
      }
    }

    final operations = _credentialRecords;
    if (input.material != null &&
        (input.material!.length > 1048576 ||
            input.material!.any((v) => v < 0 || v > 255))) {
      throw const AccessFailure('invalid_credential_content');
    }
    final hash = input._hash;
    final previous = await operations.credentialRecordReceipt(id);
    check();
    if (previous != null) {
      if (previous.inputHash != hash ||
          previous.commandDigest != input.commandDigest) {
        throw const AccessFailure('operation_conflict');
      }
      return previous;
    }
    final create = input.action == CredentialRecordAction.create;
    final toggle = input.action == CredentialRecordAction.setEnabled;
    final replace = input.action == CredentialRecordAction.replaceMaterial;
    if (!create &&
        (input.credentialId == null ||
            (input.expectedRevision ?? 0) < 1 ||
            (input.expectedMaterialVersion ?? 0) < 1)) {
      throw const AccessFailure('invalid_credential_operation');
    }
    final old = create
        ? null
        : _expectCredential(
            input.credentialId ?? '',
            input.expectedRevision ?? 0,
          );
    if (!create && input.expectedMaterialVersion != old!.version) {
      throw const AccessFailure('credential_conflict');
    }
    if ((create &&
            (input.credentialId != null ||
                input.expectedRevision != null ||
                input.expectedMaterialVersion != null ||
                input.form == null)) ||
        (!create && input.form != null) ||
        (toggle &&
            (input.enabled == null ||
                input.name != null ||
                input.publicPurpose != null ||
                input.privateNote != null ||
                input.suggestedBinding != null ||
                input.material != null ||
                input.fileName != null ||
                input.linkedItemIds != null ||
                input.discoverable != null ||
                input.updateExpiry ||
                input.expiresAt != null)) ||
        (!toggle && input.enabled != null) ||
        (!input.updateExpiry && input.expiresAt != null)) {
      throw const AccessFailure('invalid_credential_operation');
    }
    final form = input.form ?? old!.form;
    if (!toggle) {
      if (input.name == null ||
          input.publicPurpose == null ||
          input.privateNote == null ||
          input.suggestedBinding == null) {
        throw const AccessFailure('invalid_credential_metadata');
      }
      _validateCredentialMetadata(
        input.name!,
        input.publicPurpose!,
        input.privateNote!,
        input.suggestedBinding!,
      );
    }
    if (create || replace) {
      if (input.material == null) {
        throw const AccessFailure('invalid_credential_content');
      }
      if (form == CredentialForm.file) {
        _validateFile(input.fileName ?? '', input.material!);
      } else {
        if (input.fileName != null ||
            input.material!.isEmpty ||
            input.material!.length > 65536 ||
            input.material!.any((v) => v < 0 || v > 255)) {
          throw const AccessFailure('invalid_credential_content');
        }
        try {
          if (utf8.decode(input.material!).contains('\u0000')) {
            throw const FormatException();
          }
        } on FormatException {
          throw const AccessFailure('invalid_credential_content');
        }
      }
    } else if (input.material != null || input.fileName != null) {
      throw const AccessFailure('invalid_credential_operation');
    }
    final links = input.linkedItemIds ?? old?.linkedItemIds ?? const <String>[];
    if (links.length > 200 ||
        links.toSet().length != links.length ||
        (input.linkedItemIds != null &&
            links.any((id) => !information.any((item) => item.id == id)))) {
      throw const AccessFailure('invalid_credential_links');
    }
    final now = _service._clock().toUtc();
    final c = create
        ? ManagedCredential(
            id: _service._secret(),
            name: input.name!.trim(),
            publicPurpose: input.publicPurpose!,
            privateNote: input.privateNote!,
            form: form,
            version: 1,
            revision: 1,
            suggestedBinding: input.suggestedBinding!,
            createdAt: now,
            modifiedAt: now,
            fileName: input.fileName,
            byteLength: input.material!.length,
            expiresAt: input.expiresAt?.toUtc(),
            discoverable: input.discoverable ?? false,
            linkedItemIds: links,
          )
        : old!.copy(
            name: toggle ? null : input.name!.trim(),
            publicPurpose: input.publicPurpose,
            privateNote: input.privateNote,
            suggestedBinding: input.suggestedBinding,
            enabled: input.enabled,
            discoverable: input.discoverable,
            version: replace ? old.version + 1 : null,
            fileName: replace ? input.fileName : null,
            byteLength: replace ? input.material!.length : null,
            expiresAt: input.updateExpiry ? input.expiresAt?.toUtc() : null,
            clearExpiry: input.updateExpiry && input.expiresAt == null,
            linkedItemIds: input.linkedItemIds,
            invalidateUse:
                toggle ||
                replace ||
                (input.updateExpiry &&
                    old.expiresAt != input.expiresAt?.toUtc()),
            modifiedAt: now,
          );
    final vault = _vault;
    final materials = <CredentialMaterial>[
      for (final m in vault.credentialMaterials)
        replace && m.credentialId == c.id && m.retiredAt == null
            ? m.retire(now)
            : m,
      if (create || replace)
        CredentialMaterial(
          credentialId: c.id,
          version: c.version,
          bytes: input.material!,
          createdAt: now,
          fileName: input.fileName,
        ),
    ];
    final receipt = CredentialRecordReceipt(
      operationId: id,
      action: input.action,
      inputHash: hash,
      commandDigest: input.commandDigest,
      credentialId: c.id,
      baseRevision: old?.revision,
      baseMaterialVersion: old?.version,
      revision: c.revision,
      materialVersion: c.version,
      useGeneration: c.useGeneration,
    );
    await operations.commitCredentialRecord(
      CredentialRecordChange(
        receipt: receipt,
        previousDigest: credentialVaultDigest(
          vault.managedCredentials,
          vault.credentialMaterials,
        ),
        credentials: [
          for (final previous in vault.managedCredentials)
            previous.id == c.id ? c : previous,
          if (create) c,
        ],
        materials: materials,
        validate: check,
      ),
    );
    return receipt;
  });
}
