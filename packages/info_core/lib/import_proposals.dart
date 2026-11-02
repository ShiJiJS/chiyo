import 'information.dart';

enum ImportProposalState { pending, confirmed, rejected }

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
    Iterable<String> tagIds = const [],
    this.suggestedDirectory = '',
    Iterable<String> suggestedTags = const [],
    this.suggestedTemplate = '',
    this.templateId,
    this.templateVersion,
    this.templateDigest,
    Map<String, Object?> values = const {},
    this.layout,
    Iterable<String?> fieldKeys = const [],
  }) : fields = List.unmodifiable(fields),
       tagIds = List.unmodifiable(tagIds),
       values = _freezeImportValue(values) as Map<String, Object?>,
       fieldKeys = List.unmodifiable(fieldKeys),
       suggestedTags = List.unmodifiable(suggestedTags);
  final String name, description;
  final List<FieldInput> fields;
  final String? directoryId;
  final List<String> tagIds;
  final String suggestedDirectory, suggestedTemplate;
  final List<String> suggestedTags;
  final String? templateId, templateVersion, templateDigest;
  final Map<String, Object?> values;
  final InformationLayout? layout;
  final List<String?> fieldKeys;

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
    } else
      'fields': [for (final f in fields) f.toJson()],
  };

  Map<String, Object?> toJson() => {
    'name': name,
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
      'layout': layout?.toJson(),
      'fieldKeys': fieldKeys,
    },
  };

  factory ImportItemInput.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
          (key) => !const {
            'name',
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
    tagIds: (json['tagIds'] as List? ?? []).cast<String>(),
    suggestedDirectory: json['suggestedDirectory'] as String? ?? '',
    suggestedTags: (json['suggestedTags'] as List? ?? []).cast<String>(),
    suggestedTemplate: json['suggestedTemplate'] as String? ?? '',
    templateId: json['templateId'] as String?,
    templateVersion: json['templateVersion'] as String?,
    templateDigest: json['templateDigest'] as String?,
    values: Map<String, Object?>.from(json['values'] as Map? ?? {}),
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
  }) : items = state == ImportProposalState.pending
           ? List.unmodifiable(items)
           : const [],
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
  );
}
