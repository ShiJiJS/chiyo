import 'information.dart';

enum ImportProposalState { pending, confirmed, rejected }

/// A reference to a candidate, not a grant or a pre-created library record.
class ImportPendingReference {
  ImportPendingReference(this.kind, this.itemKey, {this.proposalId}) {
    if (!{'information', 'credential'}.contains(kind) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(itemKey) ||
        proposalId != null &&
            (proposalId!.isEmpty || proposalId!.length > 200)) {
      throw const FormatException('Invalid pending reference');
    }
  }
  final String kind, itemKey;
  final String? proposalId;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'itemKey': itemKey,
    if (proposalId != null) 'proposalId': proposalId,
  };
  factory ImportPendingReference.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((k) => !{'kind', 'itemKey', 'proposalId'}.contains(k))) {
      throw const FormatException('Invalid pending reference');
    }
    return ImportPendingReference(
      json['kind'] as String,
      json['itemKey'] as String,
      proposalId: json['proposalId'] as String?,
    );
  }
}

/// Confirmation facts remain available even after the resulting item is deleted.
class ImportReceipt {
  const ImportReceipt(this.id, this.version);
  final String id;
  final int version;
}

/// New information only: no existing item or field identities can be supplied.
class ImportItemInput {
  ImportItemInput(
    this.name,
    this.description,
    Iterable<FieldInput> fields, {
    this.directoryId,
    this.key = '',
    Iterable<String> tagIds = const [],
    this.suggestedDirectory = '',
    Iterable<String> suggestedTags = const [],
    this.suggestedTemplate = '',
    this.templateId,
    this.templateVersion,
    this.templateDigest,
    Map<String, Object?> values = const {},
    this.layout,
    Map<String, List<InformationRelationRef>> relations = const {},
    Map<String, List<ImportPendingReference>> pendingRelations = const {},
    Iterable<String?> fieldKeys = const [],
  }) : fields = List.unmodifiable(fields),
       tagIds = List.unmodifiable(tagIds),
       values = _freezeImportValue(values) as Map<String, Object?>,
       fieldKeys = List.unmodifiable(fieldKeys),
       relations = Map.unmodifiable({
         for (final e in relations.entries)
           e.key: List<InformationRelationRef>.unmodifiable(e.value),
       }),
       pendingRelations = Map.unmodifiable({
         for (final e in pendingRelations.entries)
           e.key: List<ImportPendingReference>.unmodifiable(e.value),
       }),
       suggestedTags = List.unmodifiable(suggestedTags);
  final String name, description;
  final String key;
  final List<FieldInput> fields;
  final String? directoryId;
  final List<String> tagIds;
  final String suggestedDirectory, suggestedTemplate;
  final List<String> suggestedTags;
  final String? templateId, templateVersion, templateDigest;
  final Map<String, Object?> values;
  final InformationLayout? layout;
  final List<String?> fieldKeys;
  final Map<String, List<InformationRelationRef>> relations;
  final Map<String, List<ImportPendingReference>> pendingRelations;
  ImportItemInput withKey(String key) =>
      ImportItemInput.fromPrivateJson({...toJson(), 'key': key});
  Map<String, Object?> get relationJson => {
    for (final k in {...relations.keys, ...pendingRelations.keys})
      k: [
        for (final r in relations[k] ?? <InformationRelationRef>[]) r.toJson(),
        for (final r in pendingRelations[k] ?? <ImportPendingReference>[])
          r.toJson(),
      ],
  };

  InformationLayout? bindLayout(List<InformationField> assigned) {
    if (layout == null) return null;
    if (assigned.length != fieldKeys.length) {
      throw const FormatException('Invalid import layout');
    }
    return layout!.withFieldIds({
      for (var i = 0; i < assigned.length; i++)
        if (fieldKeys[i] != null) fieldKeys[i]!: assigned[i].id,
    });
  }

  Map<String, Object?> get submissionJson => {
    'name': name,
    if (key.isNotEmpty) 'key': key,
    'description': description,
    'directoryId': directoryId,
    'tagIds': tagIds,
    'suggestedDirectory': suggestedDirectory,
    'suggestedTags': suggestedTags,
    'suggestedTemplate': suggestedTemplate,
    if (templateId != null) ...{
      'templateId': templateId,
      'templateVersion': templateVersion,
      'templateDigest': templateDigest,
      'values': values,
      'relations': relationJson,
    } else
      'fields': [for (final f in fields) f.toJson()],
  };

  Map<String, Object?> toJson() => {
    'name': name,
    if (key.isNotEmpty) 'key': key,
    'description': description,
    'directoryId': directoryId,
    'tagIds': tagIds,
    'suggestedDirectory': suggestedDirectory,
    'suggestedTags': suggestedTags,
    'suggestedTemplate': suggestedTemplate,
    'fields': [for (final f in fields) f.toJson()],
    if (templateId != null) ...{
      'templateId': templateId,
      'templateVersion': templateVersion,
      'templateDigest': templateDigest,
      'values': values,
      'relations': relationJson,
      'layout': layout?.toJson(),
      'fieldKeys': fieldKeys,
    },
  };

  factory ImportItemInput.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
          (key) => !const {
            'name',
            'key',
            'description',
            'directoryId',
            'tagIds',
            'suggestedDirectory',
            'suggestedTags',
            'suggestedTemplate',
            'templateId',
            'templateVersion',
            'templateDigest',
            'values',
            'fields',
            'relations',
          }.contains(key),
        ) ||
        json['templateId'] != null && json.containsKey('fields')) {
      throw const FormatException(
        'Agent cannot supply compiled fields or layout',
      );
    }
    return ImportItemInput._read(json, private: false);
  }

  factory ImportItemInput.fromPrivateJson(Map<String, dynamic> json) =>
      ImportItemInput._read(json, private: true);

  factory ImportItemInput._read(
    Map<String, dynamic> json, {
    required bool private,
  }) => ImportItemInput(
    json['name'] as String,
    json['description'] as String? ?? '',
    (json['fields'] as List? ?? []).map(
      (dynamic f) => FieldInput.fromJson(f as Map<String, dynamic>),
    ),
    directoryId: json['directoryId'] as String?,
    key: json['key'] as String? ?? '',
    tagIds: (json['tagIds'] as List? ?? []).cast<String>(),
    suggestedDirectory: json['suggestedDirectory'] as String? ?? '',
    suggestedTags: (json['suggestedTags'] as List? ?? []).cast<String>(),
    suggestedTemplate: json['suggestedTemplate'] as String? ?? '',
    templateId: json['templateId'] as String?,
    templateVersion: json['templateVersion'] as String?,
    templateDigest: json['templateDigest'] as String?,
    values: Map<String, Object?>.from(json['values'] as Map? ?? {}),
    relations: importRelationsFromJson(json['relations']),
    pendingRelations: importPendingRelationsFromJson(json['relations']),
    layout: private && json['layout'] != null
        ? InformationLayout.fromJson(
            Map<String, dynamic>.from(json['layout'] as Map),
          )
        : null,
    fieldKeys: private
        ? (json['fieldKeys'] as List? ?? []).cast<String?>()
        : const [],
  );
}

Map<String, List<InformationRelationRef>> importRelationsFromJson(
  Object? json,
) {
  final map = json == null
      ? const <String, dynamic>{}
      : Map<String, dynamic>.from(json as Map);
  if (map.length > 200) throw const FormatException('Too many relation groups');
  return {
    for (final e in map.entries)
      e.key: [
        for (final ref in e.value as List)
          if (!(ref as Map).containsKey('itemKey'))
            InformationRelationRef.fromJson(Map<String, dynamic>.from(ref)),
      ],
  };
}

Map<String, List<ImportPendingReference>> importPendingRelationsFromJson(
  Object? json,
) {
  final map = json == null
      ? const <String, dynamic>{}
      : Map<String, dynamic>.from(json as Map);
  if (map.length > 200) throw const FormatException('Too many relation groups');
  return {
    for (final e in map.entries)
      if ((e.value as List).any((r) => (r as Map).containsKey('itemKey')))
        e.key: [
          for (final ref in e.value as List)
            if ((ref as Map).containsKey('itemKey'))
              ImportPendingReference.fromJson(Map<String, dynamic>.from(ref)),
        ],
  };
}

Object? _freezeImportValue(Object? value, [int depth = 0]) {
  if (depth > 16) throw const FormatException('Import value nesting limit');
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final e in value.entries)
        e.key as String: _freezeImportValue(e.value, depth + 1),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((e) => _freezeImportValue(e, depth + 1)),
    );
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw const FormatException('Invalid import value');
}

/// Owner-only snapshot. sessionBinding is a random correlation ID, never a
/// session secret or a credential and never included in agent responses.
class ImportProposal {
  ImportProposal({
    required this.id,
    required this.sessionBinding,
    required this.chatLabel,
    required this.createdAt,
    required Iterable<ImportItemInput> items,
    this.state = ImportProposalState.pending,
    this.version = 1,
    Iterable<String> createdItemIds = const [],
    Iterable<int> createdItemVersions = const [],
    int? itemCount,
    this.agentName = '',
    this.purpose = '',
    int? fieldCount,
    Iterable<String>? itemNames,
    Iterable<String> approvedKeys = const [],
    Iterable<String> createdItemKeys = const [],
    Iterable<String> rejectedKeys = const [],
    Map<String, String>? candidateNames,
    this.admissionVersion = 1,
  }) : items = state == ImportProposalState.pending
           ? List.unmodifiable(
               items.indexed.map(
                 (e) => e.$2.key.isEmpty ? e.$2.withKey('item-${e.$1}') : e.$2,
               ),
             )
           : const [],
       approvedKeys = Set.unmodifiable(approvedKeys),
       rejectedKeys = Set.unmodifiable(rejectedKeys),
       createdItemKeys = List.unmodifiable(
         createdItemKeys.isEmpty
             ? createdItemIds.indexed.map((e) => 'item-${e.$1}')
             : createdItemKeys,
       ),
       candidateNames = Map.unmodifiable(
         candidateNames ??
             {
               for (final (index, item) in items.indexed)
                 (item.key.isEmpty ? 'item-$index' : item.key): item.name,
               if (items.isEmpty)
                 for (final (index, name) in (itemNames ?? <String>[]).indexed)
                   'item-$index': name,
             },
       ),
       itemNames = List.unmodifiable(itemNames ?? items.map((i) => i.name)),
       itemCount = itemCount ?? items.length,
       fieldCount =
           fieldCount ?? items.fold<int>(0, (n, i) => n + i.fields.length),
       createdItemIds = List.unmodifiable(createdItemIds),
       createdItemVersions = List.unmodifiable(
         createdItemVersions.isEmpty
             ? createdItemIds.map((_) => 1)
             : createdItemVersions,
       );
  final String id, sessionBinding, chatLabel;
  final String agentName, purpose;
  final DateTime createdAt;
  final List<ImportItemInput> items;
  final ImportProposalState state;
  final int version;
  final List<String> createdItemIds;
  final List<int> createdItemVersions;
  final int itemCount;
  final int fieldCount;
  final int admissionVersion;
  final Set<String> approvedKeys, rejectedKeys;
  final List<String> createdItemKeys;
  final Map<String, String> candidateNames;
  bool get awaitingAdmission =>
      state == ImportProposalState.pending &&
      items.isNotEmpty &&
      items.every((i) => approvedKeys.contains(i.key));
  ImportReceipt? receiptFor(String key) {
    final index = createdItemKeys.indexOf(key);
    return index < 0
        ? null
        : ImportReceipt(createdItemIds[index], createdItemVersions[index]);
  }

  ImportProposal revise({
    Iterable<ImportItemInput>? items,
    Iterable<String>? approvedKeys,
    Iterable<String>? rejectedKeys,
    Iterable<String>? createdItemKeys,
    Iterable<String>? createdItemIds,
    Iterable<int>? createdItemVersions,
    ImportProposalState? state,
    int? version,
  }) => ImportProposal(
    id: id,
    sessionBinding: sessionBinding,
    chatLabel: chatLabel,
    createdAt: createdAt,
    items: items ?? this.items,
    state: state ?? this.state,
    version: version ?? this.version + 1,
    approvedKeys: approvedKeys ?? this.approvedKeys,
    rejectedKeys: rejectedKeys ?? this.rejectedKeys,
    createdItemKeys: createdItemKeys ?? this.createdItemKeys,
    createdItemIds: createdItemIds ?? this.createdItemIds,
    createdItemVersions: createdItemVersions ?? this.createdItemVersions,
    candidateNames: {
      ...candidateNames,
      for (final i in items ?? this.items) i.key: i.name,
    },
    itemNames: itemNames,
    itemCount: itemCount,
    fieldCount: fieldCount,
    agentName: agentName,
    purpose: purpose,
  );

  /// Public titles only. Terminal proposals never retain private field snapshots.
  final List<String> itemNames;
  List<ImportReceipt> get receipts => List.unmodifiable([
    for (var i = 0; i < createdItemIds.length; i++)
      ImportReceipt(createdItemIds[i], createdItemVersions[i]),
  ]);
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionBinding': sessionBinding,
    'chatLabel': chatLabel,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'version': version,
    'state': state.name,
    'items': items.map((i) => i.toJson()).toList(),
    'createdItemIds': createdItemIds,
    'createdItemVersions': createdItemVersions,
    'itemCount': itemCount,
    'agentName': agentName,
    'purpose': purpose,
    'fieldCount': fieldCount,
    'itemNames': itemNames,
    'admissionVersion': admissionVersion,
    'approvedKeys': approvedKeys.toList(),
    'rejectedKeys': rejectedKeys.toList(),
    'createdItemKeys': createdItemKeys,
    'candidateNames': candidateNames,
  };
  factory ImportProposal.fromJson(Map<String, dynamic> json) => ImportProposal(
    id: json['id'] as String,
    sessionBinding: json['sessionBinding'] as String,
    chatLabel: json['chatLabel'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    items: (json['items'] as List).map(
      (dynamic i) => ImportItemInput.fromPrivateJson(i as Map<String, dynamic>),
    ),
    state: ImportProposalState.values.byName(json['state'] as String),
    version: json['version'] as int,
    createdItemIds: (json['createdItemIds'] as List).cast<String>(),
    createdItemVersions: (json['createdItemVersions'] as List? ?? [])
        .cast<int>(),
    itemCount: json['itemCount'] as int?,
    agentName: json['agentName'] as String? ?? '',
    purpose: json['purpose'] as String? ?? '',
    fieldCount: json['fieldCount'] as int?,
    itemNames: (json['itemNames'] as List?)?.cast<String>(),
    admissionVersion: json['admissionVersion'] as int? ?? 0,
    approvedKeys: (json['approvedKeys'] as List? ?? []).cast<String>(),
    rejectedKeys: (json['rejectedKeys'] as List? ?? []).cast<String>(),
    createdItemKeys: (json['createdItemKeys'] as List? ?? []).cast<String>(),
    candidateNames: json['candidateNames'] == null
        ? null
        : Map<String, String>.from(json['candidateNames'] as Map),
  );
}
