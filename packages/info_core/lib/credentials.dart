import 'dart:convert';
import 'information_layout.dart';

enum CredentialForm { string, file }

enum CredentialAvailability { available, disabled, expired, deleted }

/// Owner metadata only. Neither this object nor its JSON contains secret bytes.
class ManagedCredential {
  ManagedCredential({
    required this.id,
    required this.name,
    required this.publicPurpose,
    required this.privateNote,
    required this.form,
    required this.version,
    required this.revision,
    required this.suggestedBinding,
    required this.createdAt,
    required this.modifiedAt,
    this.discoverable = false,
    this.enabled = true,
    this.useGeneration = 1,
    this.expiresAt,
    this.deletedAt,
    this.purgedAt,
    this.fileName,
    this.byteLength = 0,
    this.directoryId,
    this.template,
    Iterable<String> tagIds = const [],
    Iterable<String> linkedItemIds = const [],
  }) : linkedItemIds = List.unmodifiable(linkedItemIds),
       tagIds = List.unmodifiable(tagIds) {
    bool invalidId(String id) =>
        id.isEmpty || id.length > 200 || id.contains('\u0000');
    if (directoryId != null && invalidId(directoryId!) ||
        this.tagIds.length > 100 ||
        this.tagIds.toSet().length != this.tagIds.length ||
        this.tagIds.any(invalidId)) {
      throw const FormatException('Invalid credential classification');
    }
  }
  final String id, name, publicPurpose, privateNote, suggestedBinding;
  final CredentialForm form;
  final int version, revision, byteLength, useGeneration;
  final DateTime createdAt, modifiedAt;
  final DateTime? expiresAt, deletedAt, purgedAt;
  final bool discoverable, enabled;
  final String? fileName;
  final List<String> linkedItemIds;
  final String? directoryId;
  final List<String> tagIds;
  final InformationLayout? template;
  CredentialAvailability availability(DateTime now) => deletedAt != null
      ? CredentialAvailability.deleted
      : !enabled
      ? CredentialAvailability.disabled
      : expiresAt != null && !now.isBefore(expiresAt!)
      ? CredentialAvailability.expired
      : CredentialAvailability.available;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'publicPurpose': publicPurpose,
    'privateNote': privateNote,
    'form': form.name,
    'version': version,
    'revision': revision,
    'useGeneration': useGeneration,
    'suggestedBinding': suggestedBinding,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'modifiedAt': modifiedAt.toUtc().toIso8601String(),
    'discoverable': discoverable,
    'enabled': enabled,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'purgedAt': purgedAt?.toUtc().toIso8601String(),
    'fileName': fileName,
    'byteLength': byteLength,
    'linkedItemIds': linkedItemIds,
    if (template != null) 'template': template!.toJson(),
    if (directoryId != null || tagIds.isNotEmpty) ...{
      'directoryId': directoryId,
      'tagIds': tagIds,
    },
  };
  factory ManagedCredential.fromJson(Map<String, dynamic> j) {
    if (j.containsKey('directoryId') != j.containsKey('tagIds') ||
        j.containsKey('tagIds') && j['tagIds'] is! List) {
      throw const FormatException('Invalid credential classification');
    }
    return ManagedCredential(
      id: j['id'] as String,
      name: j['name'] as String,
      publicPurpose: j['publicPurpose'] as String,
      privateNote: j['privateNote'] as String,
      form: CredentialForm.values.byName(j['form'] as String),
      version: j['version'] as int,
      revision: j['revision'] as int,
      useGeneration: j['useGeneration'] as int? ?? 1,
      suggestedBinding: j['suggestedBinding'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      modifiedAt: DateTime.parse(j['modifiedAt'] as String),
      discoverable: j['discoverable'] as bool,
      enabled: j['enabled'] as bool,
      expiresAt: j['expiresAt'] == null
          ? null
          : DateTime.parse(j['expiresAt'] as String),
      deletedAt: j['deletedAt'] == null
          ? null
          : DateTime.parse(j['deletedAt'] as String),
      purgedAt: j['purgedAt'] == null
          ? null
          : DateTime.parse(j['purgedAt'] as String),
      fileName: j['fileName'] as String?,
      byteLength: j['byteLength'] as int,
      linkedItemIds: (j['linkedItemIds'] as List).cast<String>(),
      directoryId: j['directoryId'] as String?,
      tagIds: (j['tagIds'] as List? ?? const []).cast<String>(),
      template: j['template'] == null
          ? null
          : InformationLayout.fromJson(
              Map<String, dynamic>.from(j['template'] as Map),
            ),
    );
  }
  ManagedCredential copy({
    String? name,
    String? publicPurpose,
    String? privateNote,
    String? suggestedBinding,
    bool? discoverable,
    bool? enabled,
    int? version,
    DateTime? expiresAt,
    bool clearExpiry = false,
    DateTime? deletedAt,
    DateTime? purgedAt,
    bool restore = false,
    String? fileName,
    int? byteLength,
    Iterable<String>? linkedItemIds,
    String? directoryId,
    bool clearDirectory = false,
    Iterable<String>? tagIds,
    required DateTime modifiedAt,
    bool invalidateUse = false,
  }) => ManagedCredential(
    id: id,
    name: name ?? this.name,
    publicPurpose: publicPurpose ?? this.publicPurpose,
    privateNote: privateNote ?? this.privateNote,
    form: form,
    version: version ?? this.version,
    revision: revision + 1,
    useGeneration: useGeneration + (invalidateUse ? 1 : 0),
    suggestedBinding: suggestedBinding ?? this.suggestedBinding,
    createdAt: createdAt,
    modifiedAt: modifiedAt,
    discoverable: discoverable ?? this.discoverable,
    enabled: enabled ?? this.enabled,
    expiresAt: clearExpiry ? null : expiresAt ?? this.expiresAt,
    deletedAt: restore ? null : deletedAt ?? this.deletedAt,
    purgedAt: purgedAt ?? this.purgedAt,
    fileName: fileName ?? this.fileName,
    byteLength: byteLength ?? this.byteLength,
    linkedItemIds: linkedItemIds ?? this.linkedItemIds,
    directoryId: clearDirectory ? null : directoryId ?? this.directoryId,
    tagIds: tagIds ?? this.tagIds,
    template: _templateAfterLinks(linkedItemIds),
  );

  InformationLayout? _templateAfterLinks(Iterable<String>? links) {
    final old = template;
    if (old == null || links == null) return old;
    final targets = links.toSet();
    final groups = <String, List<InformationRelationRef>>{
      for (final e in old.relations.entries)
        e.key: [
          for (final r in e.value)
            if (r.kind != 'information' || targets.contains(r.id)) r,
        ],
    };
    final retained = {
      for (final r in groups.values.expand((v) => v))
        if (r.kind == 'information') r.id,
    };
    final added = targets.difference(retained);
    if (added.isNotEmpty) {
      groups['ownerLinks'] = [
        ...?groups['ownerLinks'],
        for (final id in added) InformationRelationRef('information', id),
      ];
    }
    return InformationLayout(
      typeId: old.typeId,
      snapshot: old.snapshot,
      fieldIds: old.fieldIds,
      relations: groups,
    );
  }
}

/// Desktop repository capability; never returned by AgentAccess or OwnerAccess.
/// SQLCipher encrypts the complete payload, including bytes. Versions never mutate.
class CredentialMaterial {
  CredentialMaterial({
    required this.credentialId,
    required this.version,
    required Iterable<int> bytes,
    required this.createdAt,
    this.retiredAt,
    this.fileName,
  }) : bytes = List.unmodifiable(bytes);
  final String credentialId;
  final int version;
  final List<int> bytes;
  final DateTime createdAt;
  final DateTime? retiredAt;
  final String? fileName;
  CredentialMaterial retire(DateTime at) => CredentialMaterial(
    credentialId: credentialId,
    version: version,
    bytes: bytes,
    createdAt: createdAt,
    retiredAt: retiredAt ?? at,
    fileName: fileName,
  );
  Map<String, Object?> toStorageJson() => {
    'credentialId': credentialId,
    'version': version,
    'bytes': base64Encode(bytes),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'retiredAt': retiredAt?.toUtc().toIso8601String(),
    'fileName': fileName,
  };
  factory CredentialMaterial.fromStorageJson(Map<String, dynamic> j) =>
      CredentialMaterial(
        credentialId: j['credentialId'] as String,
        version: j['version'] as int,
        bytes: base64Decode(j['bytes'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
        retiredAt: j['retiredAt'] == null
            ? null
            : DateTime.parse(j['retiredAt'] as String),
        fileName: j['fileName'] as String?,
      );
  @override
  String toString() => 'CredentialMaterial($credentialId, v$version)';
}

abstract interface class CredentialRepository {
  List<ManagedCredential> get managedCredentials;
  List<CredentialMaterial> get credentialMaterials;

  /// Atomically replaces the complete vault snapshot, then publishes it in memory.
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  );
}

class CredentialCatalogPage {
  CredentialCatalogPage(
    Iterable<Map<String, Object?>> credentials,
    this.nextCursor,
  ) : credentials = List.unmodifiable(
        credentials.map(Map<String, Object?>.unmodifiable),
      );
  final List<Map<String, Object?>> credentials;
  final String? nextCursor;
  Map<String, Object?> toJson() => {
    'protocolVersion': 1,
    'status': 'ok',
    'credentials': credentials,
    'nextCursor': nextCursor,
  };
}

class CredentialImpact {
  CredentialImpact(this.credential, Iterable<String> linkedItemIds)
    : linkedItemIds = List.unmodifiable(linkedItemIds);
  final ManagedCredential credential;
  final List<String> linkedItemIds;

  /// D6 adds actual pending grant counts; never fabricate a zero before D6 exists.
  bool get usageTrackingAvailable => false;
}

class CredentialVersionInfo {
  CredentialVersionInfo(CredentialMaterial material)
    : version = material.version,
      createdAt = material.createdAt,
      retiredAt = material.retiredAt,
      fileName = material.fileName,
      byteLength = material.bytes.length;
  final int version, byteLength;
  final DateTime createdAt;
  final DateTime? retiredAt;
  final String? fileName;
}
