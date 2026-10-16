import 'information.dart';

enum ImportProposalState { pending, confirmed, rejected }

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
  }) : fields = List.unmodifiable(fields),
       tagIds = List.unmodifiable(tagIds),
       suggestedTags = List.unmodifiable(suggestedTags);
  final String name, description;
  final List<FieldInput> fields;
  final String? directoryId;
  final List<String> tagIds;
  final String suggestedDirectory, suggestedTemplate;
  final List<String> suggestedTags;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'directoryId': directoryId,
    'tagIds': tagIds,
    'suggestedDirectory': suggestedDirectory,
    'suggestedTags': suggestedTags,
    'suggestedTemplate': suggestedTemplate,
    'fields': [
      for (final f in fields)
        {
          'name': f.name,
          'description': f.description,
          'value': f.value,
          'kind': f.kind.name,
        },
    ],
  };

  factory ImportItemInput.fromJson(Map<String, dynamic> json) =>
      ImportItemInput(
        json['name'] as String,
        json['description'] as String? ?? '',
        (json['fields'] as List).map(
          (dynamic f) => FieldInput(
            f['name'] as String,
            f['description'] as String? ?? '',
            f['value'] as String,
            kind: FieldKind.values.byName(f['kind'] as String? ?? 'structured'),
          ),
        ),
        directoryId: json['directoryId'] as String?,
        tagIds: (json['tagIds'] as List? ?? []).cast<String>(),
        suggestedDirectory: json['suggestedDirectory'] as String? ?? '',
        suggestedTags: (json['suggestedTags'] as List? ?? []).cast<String>(),
        suggestedTemplate: json['suggestedTemplate'] as String? ?? '',
      );
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
  }) : items = List.unmodifiable(items),
       createdItemIds = List.unmodifiable(createdItemIds);
  final String id, sessionBinding, chatLabel;
  final DateTime createdAt;
  final List<ImportItemInput> items;
  final ImportProposalState state;
  final int version;
  final List<String> createdItemIds;
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionBinding': sessionBinding,
    'chatLabel': chatLabel,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'version': version,
    'state': state.name,
    'items': items.map((i) => i.toJson()).toList(),
    'createdItemIds': createdItemIds,
  };
  factory ImportProposal.fromJson(Map<String, dynamic> json) => ImportProposal(
    id: json['id'] as String,
    sessionBinding: json['sessionBinding'] as String,
    chatLabel: json['chatLabel'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    items: (json['items'] as List).map(
      (dynamic i) => ImportItemInput.fromJson(i as Map<String, dynamic>),
    ),
    state: ImportProposalState.values.byName(json['state'] as String),
    version: json['version'] as int,
    createdItemIds: (json['createdItemIds'] as List).cast<String>(),
  );
}
