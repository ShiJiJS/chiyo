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
    'fields': [for (final f in fields) f.toJson()],
  };

  factory ImportItemInput.fromJson(Map<String, dynamic> json) =>
      ImportItemInput(
        json['name'] as String,
        json['description'] as String? ?? '',
        (json['fields'] as List).map(
          (dynamic f) => FieldInput.fromJson(f as Map<String, dynamic>),
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
      (dynamic i) => ImportItemInput.fromJson(i as Map<String, dynamic>),
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
