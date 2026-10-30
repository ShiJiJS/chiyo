import 'information.dart';

enum UpdateProposalState { pending, confirmed, rejected, conflicted }

enum FieldChangeKind { correct, add, replace, remove }

/// Operations state intent explicitly; semantic replacements never keep IDs.
class FieldChange {
  const FieldChange.correct(String id, String this.value)
    : kind = FieldChangeKind.correct,
      fieldId = id,
      field = null;
  const FieldChange.add(FieldInput input)
    : kind = FieldChangeKind.add,
      fieldId = null,
      value = null,
      field = input;
  const FieldChange.replace(String id, FieldInput input)
    : kind = FieldChangeKind.replace,
      fieldId = id,
      value = null,
      field = input;
  const FieldChange.remove(String id)
    : kind = FieldChangeKind.remove,
      fieldId = id,
      value = null,
      field = null;
  final FieldChangeKind kind;
  final String? fieldId, value;
  final FieldInput? field;
  Map<String, Object?> toJson() => {
    'operation': kind.name,
    if (fieldId != null) 'fieldId': fieldId,
    if (value != null) 'value': value,
    if (field != null) 'field': field!.toJson(),
  };
  factory FieldChange.fromJson(Map<String, dynamic> json) {
    FieldInput input() {
      final f = json['field'] as Map<String, dynamic>;
      return FieldInput.fromJson(f);
    }

    return switch (FieldChangeKind.values.byName(json['operation'] as String)) {
      FieldChangeKind.correct => FieldChange.correct(
        json['fieldId'] as String,
        json['value'] as String,
      ),
      FieldChangeKind.add => FieldChange.add(input()),
      FieldChangeKind.replace => FieldChange.replace(
        json['fieldId'] as String,
        input(),
      ),
      FieldChangeKind.remove => FieldChange.remove(json['fieldId'] as String),
    };
  }
}

class UpdateInput {
  UpdateInput(
    this.itemId,
    this.baseVersion,
    Iterable<FieldChange> changes, {
    this.name,
    this.description,
  }) : changes = List.unmodifiable(changes);
  final String itemId;
  final int baseVersion;
  final List<FieldChange> changes;
  final String? name, description;
  Map<String, Object?> toJson() => {
    'itemId': itemId,
    'baseVersion': baseVersion,
    'changes': changes.map((c) => c.toJson()).toList(),
    if (name != null) 'name': name,
    if (description != null) 'description': description,
  };
  factory UpdateInput.fromJson(Map<String, dynamic> json) => UpdateInput(
    json['itemId'] as String,
    json['baseVersion'] as int,
    (json['changes'] as List).map(
      (dynamic c) => FieldChange.fromJson(c as Map<String, dynamic>),
    ),
    name: json['name'] as String?,
    description: json['description'] as String?,
  );
}

/// Owner-only proposal, containing submitted values but no authentication secrets.
class UpdateProposal {
  const UpdateProposal({
    required this.id,
    required this.sessionBinding,
    required this.chatLabel,
    required this.createdAt,
    required this.input,
    this.state = UpdateProposalState.pending,
    this.version = 1,
    this.result,
  });
  final String id, sessionBinding, chatLabel;
  final DateTime createdAt;
  final UpdateInput input;
  final UpdateProposalState state;
  final int version;
  final UpdateReceipt? result;
  UpdateProposal finish(UpdateProposalState state, {UpdateReceipt? result}) =>
      UpdateProposal(
        id: id,
        sessionBinding: sessionBinding,
        chatLabel: chatLabel,
        createdAt: createdAt,
        input: UpdateInput(input.itemId, input.baseVersion, const []),
        state: state,
        version: version + 1,
        result: result,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionBinding': sessionBinding,
    'chatLabel': chatLabel,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'input': input.toJson(),
    'state': state.name,
    'version': version,
    if (result != null)
      'result': {'itemId': result!.itemId, 'version': result!.version},
  };
  factory UpdateProposal.fromJson(Map<String, dynamic> json) => UpdateProposal(
    id: json['id'] as String,
    sessionBinding: json['sessionBinding'] as String,
    chatLabel: json['chatLabel'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    input: UpdateInput.fromJson(json['input'] as Map<String, dynamic>),
    state: UpdateProposalState.values.byName(json['state'] as String),
    version: json['version'] as int,
    result: json['result'] == null
        ? null
        : UpdateReceipt(
            json['result']['itemId'] as String,
            json['result']['version'] as int,
          ),
  );
}

/// Idempotent confirmation result; deliberately retains no submitted values.
class UpdateReceipt {
  const UpdateReceipt(this.itemId, this.version);
  final String itemId;
  final int version;
}

class UpdatePreview {
  const UpdatePreview(this.proposal, this.before, this.after);
  final UpdateProposal proposal;
  final InformationItem before, after;
}

/// Owner-only, unsaved review input. Target and base version cannot be changed.
class UpdateReview {
  UpdateReview(
    this.input, {
    this.directoryId,
    Iterable<String> tagIds = const [],
    Map<String, String> fieldDescriptions = const {},
  }) : tagIds = List.unmodifiable(tagIds),
       fieldDescriptions = Map.unmodifiable(fieldDescriptions);
  final UpdateInput input;
  final String? directoryId;
  final List<String> tagIds;
  final Map<String, String> fieldDescriptions;
}

/// A past content version, only available to the owner. Persisted encrypted.
class InformationRevision {
  const InformationRevision(this.item, this.replacedAt);
  final InformationItem item;
  final DateTime replacedAt;
}

Map<String, Object?> informationToJson(InformationItem item) => {
  'id': item.id,
  'name': item.name,
  'description': item.description,
  'version': item.version,
  'directoryId': item.directoryId,
  'tagIds': item.tagIds,
  'createdAt': item.createdAt?.toUtc().toIso8601String(),
  'modifiedAt': item.modifiedAt?.toUtc().toIso8601String(),
  'fields': [for (final f in item.fields) f.toJson()],
  if (item.layout != null) 'layout': item.layout!.toJson(),
};
InformationItem informationFromJson(Map<String, dynamic> json) =>
    InformationItem(
      json['id'] as String,
      json['name'] as String,
      json['description'] as String,
      json['version'] as int,
      (json['fields'] as List)
          .map(
            (dynamic f) => InformationField.fromJson(f as Map<String, dynamic>),
          )
          .toList(),
      layout: json['layout'] == null
          ? null
          : InformationLayout.fromJson(json['layout'] as Map<String, dynamic>),
      directoryId: json['directoryId'] as String?,
      tagIds: (json['tagIds'] as List).cast<String>(),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
      modifiedAt: json['modifiedAt'] == null
          ? null
          : DateTime.parse(json['modifiedAt'] as String),
    );
