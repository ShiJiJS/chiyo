/// UI contracts contain metadata and explicitly requested owner detail. They
/// never contain database objects, grants, executable handles or file bytes.
enum WorkspaceRecordKind { information, credential }

const workspaceDocumentFormats = {'plain': '纯文本', 'markdown': 'Markdown'};
const workspaceDocumentMaxLength = 1000000;

class WorkspaceRecordRef {
  const WorkspaceRecordRef(this.kind, this.id);
  final WorkspaceRecordKind kind;
  final String id;
  String get key => '${kind.name}:$id';
  @override
  bool operator ==(Object other) =>
      other is WorkspaceRecordRef && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

class WorkspaceDirectory {
  const WorkspaceDirectory(this.id, this.name, {this.parentId});
  final String id, name;
  final String? parentId;
}

class WorkspaceTag {
  const WorkspaceTag(this.id, this.name);
  final String id, name;
}

class WorkspaceType {
  const WorkspaceType(this.id, this.name, this.icon);
  final String id, name, icon;
}

class WorkspaceCatalog {
  WorkspaceCatalog({
    required Iterable<WorkspaceDirectory> directories,
    required Iterable<WorkspaceTag> tags,
    required Iterable<WorkspaceType> types,
    Iterable<WorkspaceType>? creatableTypes,
    Map<String, int> directoryCounts = const {},
    Map<String, int> tagCounts = const {},
    this.version = 1,
    this.recycledCount = 0,
  }) : directories = List.unmodifiable(directories),
       tags = List.unmodifiable(tags),
       types = List.unmodifiable(types),
       creatableTypes = List.unmodifiable(creatableTypes ?? types),
       directoryCounts = Map.unmodifiable(directoryCounts),
       tagCounts = Map.unmodifiable(tagCounts);
  final List<WorkspaceDirectory> directories;
  final List<WorkspaceTag> tags;
  final List<WorkspaceType> types;
  final List<WorkspaceType> creatableTypes;
  final Map<String, int> directoryCounts, tagCounts;
  final int version, recycledCount;
}

enum WorkspaceDirectoryAction { create, update, delete }

/// A full desired directory state, checked against the catalog being edited.
/// Null parent means a root directory, never a filesystem path.
class WorkspaceDirectoryChange {
  const WorkspaceDirectoryChange({
    required this.operationId,
    required this.expectedVersion,
    required this.action,
    this.directoryId,
    this.name = '',
    this.parentId,
  });
  final String operationId;
  final int expectedVersion;
  final WorkspaceDirectoryAction action;
  final String? directoryId, parentId;
  final String name;
}

class WorkspaceRecordSummary {
  WorkspaceRecordSummary({
    required this.ref,
    required this.name,
    required this.description,
    required this.type,
    required this.updatedAt,
    this.directoryId,
    Iterable<WorkspaceTag> tags = const [],
  }) : tags = List.unmodifiable(tags);
  final WorkspaceRecordRef ref;
  final String name, description;
  final WorkspaceType type;
  final DateTime updatedAt;
  final String? directoryId;
  final List<WorkspaceTag> tags;

  WorkspaceRecordSummary copyWith({
    String? name,
    String? description,
    String? directoryId,
    bool unfiled = false,
    Iterable<WorkspaceTag>? tags,
    DateTime? updatedAt,
    WorkspaceType? type,
  }) => WorkspaceRecordSummary(
    ref: ref,
    name: name ?? this.name,
    description: description ?? this.description,
    type: type ?? this.type,
    updatedAt: updatedAt ?? this.updatedAt,
    directoryId: unfiled ? null : directoryId ?? this.directoryId,
    tags: tags ?? this.tags,
  );
}

enum WorkspaceGrouping { none, type, directory }

enum WorkspaceSort { updated, name }

class WorkspaceQuery {
  const WorkspaceQuery({
    this.directoryId,
    this.keyword = '',
    this.typeId,
    this.tagId,
    this.grouping = WorkspaceGrouping.none,
    this.sort = WorkspaceSort.updated,
    this.offset = 0,
    this.limit = 50,
  });
  final String? directoryId, typeId, tagId;
  final String keyword;
  final WorkspaceGrouping grouping;
  final WorkspaceSort sort;
  final int offset, limit;

  WorkspaceQuery copyWith({
    String? directoryId,
    bool clearDirectory = false,
    String? keyword,
    String? typeId,
    bool clearType = false,
    String? tagId,
    bool clearTag = false,
    WorkspaceGrouping? grouping,
    WorkspaceSort? sort,
    int? offset,
    int? limit,
  }) => WorkspaceQuery(
    directoryId: clearDirectory ? null : directoryId ?? this.directoryId,
    keyword: keyword ?? this.keyword,
    typeId: clearType ? null : typeId ?? this.typeId,
    tagId: clearTag ? null : tagId ?? this.tagId,
    grouping: grouping ?? this.grouping,
    sort: sort ?? this.sort,
    offset: offset ?? this.offset,
    limit: limit ?? this.limit,
  );
}

class WorkspaceResults {
  WorkspaceResults({
    required Iterable<WorkspaceRecordSummary> items,
    required this.total,
    required this.offset,
    this.selection,
    this.selectionIndex,
    Map<String, int> groupCounts = const {},
  }) : items = List.unmodifiable(items),
       groupCounts = Map.unmodifiable(groupCounts);
  final List<WorkspaceRecordSummary> items;
  final int total, offset;
  final WorkspaceRecordRef? selection;
  final int? selectionIndex;
  final Map<String, int> groupCounts;
}

/// Candidate lookup reads metadata only, using the source record's snapshot
/// (or the selected type for a new record) to constrain eligible targets.
class WorkspaceRelationQuery {
  const WorkspaceRelationQuery({
    required this.typeId,
    required this.key,
    this.source,
    this.keyword = '',
    this.offset = 0,
    this.limit = 30,
  });
  final String typeId, key, keyword;
  final WorkspaceRecordRef? source;
  final int offset, limit;
}

Map<String, List<WorkspaceRecordRef>> _freezeRelations(
  Map<String, List<WorkspaceRecordRef>> relations,
) => Map.unmodifiable(
  relations.map(
    (key, refs) => MapEntry(key, List<WorkspaceRecordRef>.unmodifiable(refs)),
  ),
);

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freeze(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw ArgumentError('Only JSON-compatible display values are supported');
}

Map<String, Object?> workspaceImmutableMap(Map<String, Object?> value) =>
    _freeze(value) as Map<String, Object?>;

enum WorkspaceTemplateState { available, disabled, missing, removedDefinition }

class WorkspaceDetail {
  WorkspaceDetail({
    required this.record,
    required this.version,
    this.templateState = WorkspaceTemplateState.available,
    Map<String, Object?> definition = const {},
    Map<String, Object?> values = const {},
    Map<String, List<WorkspaceRecordRef>> relations = const {},
    Map<String, String> fieldIds = const {},
    Iterable<Map<String, Object?>> retainedFields = const [],
    Iterable<Map<String, Object?>> retainedRelations = const [],
  }) : definition = _freeze(definition) as Map<String, Object?>,
       values = _freeze(values) as Map<String, Object?>,
       relations = _freezeRelations(relations),
       fieldIds = Map.unmodifiable(fieldIds),
       retainedFields = List.unmodifiable(
         retainedFields.map(workspaceImmutableMap),
       ),
       retainedRelations = List.unmodifiable(
         retainedRelations.map(workspaceImmutableMap),
       );
  final WorkspaceRecordSummary record;
  final int version;

  /// Current catalog projection, never part of the immutable instance snapshot.
  final WorkspaceTemplateState templateState;
  final Map<String, Object?> definition, values;
  final Map<String, List<WorkspaceRecordRef>> relations;

  /// Definition keys address values; these opaque instance identities do not.
  final Map<String, String> fieldIds;

  /// Instance-owned descriptors, separate from the exact target snapshot.
  final List<Map<String, Object?>> retainedFields;
  final List<Map<String, Object?>> retainedRelations;
}

List<Map<String, Object?>> workspaceFields(WorkspaceDetail detail) => [
  for (final field in detail.definition['fields'] as List? ?? [])
    Map<String, Object?>.from(field as Map),
  ...detail.retainedFields,
];

Map<String, Object?> workspaceEditingDefinition(WorkspaceDetail detail) => {
  ...detail.definition,
  'fields': workspaceFields(detail),
  'relations': [
    for (final rule in detail.definition['relations'] as List? ?? [])
      if (!detail.retainedRelations.any((r) => r['key'] == rule['key'])) rule,
    ...detail.retainedRelations,
  ],
};

class WorkspaceEdit {
  WorkspaceEdit({
    required this.operationId,
    required this.expectedVersion,
    required this.record,
    required Map<String, Object?> values,
    Map<String, List<WorkspaceRecordRef>> relations = const {},
  }) : values = _freeze(values) as Map<String, Object?>,
       relations = _freezeRelations(relations);
  final String operationId;
  final int expectedVersion;
  final WorkspaceRecordSummary record;
  final Map<String, Object?> values;

  /// Only changed keys are replaced; untouched legacy relations survive.
  final Map<String, List<WorkspaceRecordRef>> relations;
}

class WorkspaceCreate {
  WorkspaceCreate({
    required this.operationId,
    required this.typeId,
    required this.name,
    this.expectedTemplateVersion,
    this.expectedTemplateDigest,
    this.description = '',
    this.directoryId,
    Iterable<String> tagIds = const [],
    Map<String, Object?> values = const {},
    Map<String, List<WorkspaceRecordRef>> relations = const {},
  }) : tagIds = List.unmodifiable(tagIds),
       values = _freeze(values) as Map<String, Object?>,
       relations = _freezeRelations(relations);
  final String operationId, typeId, name, description;
  final String? expectedTemplateVersion, expectedTemplateDigest;
  final String? directoryId;
  final List<String> tagIds;
  final Map<String, Object?> values;
  final Map<String, List<WorkspaceRecordRef>> relations;
}

/// Metadata name/description errors remain separate from template values with
/// the same keys. Existing other template field error keys stay compatible.
String workspaceValueErrorKey(String key) =>
    ['name', 'description'].contains(key) ? 'value:$key' : key;

class WorkspaceFailure implements Exception {
  const WorkspaceFailure(
    this.code,
    this.message, {
    this.fieldErrors = const {},
  });
  final String code, message;
  final Map<String, String> fieldErrors;
}

sealed class WorkspaceSaveResult {
  const WorkspaceSaveResult();
}

class WorkspaceSaved extends WorkspaceSaveResult {
  const WorkspaceSaved(this.detail);
  final WorkspaceDetail detail;
}

class WorkspaceRejected extends WorkspaceSaveResult {
  const WorkspaceRejected(this.failure);
  final WorkspaceFailure failure;
}
