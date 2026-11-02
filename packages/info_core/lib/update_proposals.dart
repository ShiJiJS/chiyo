import 'information.dart';
import 'import_proposals.dart';

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
    this.templateId,
    this.templateVersion,
    this.templateDigest,
    Map<String, Object?> values = const {},
    Map<String, List<InformationRelationRef>>? relations,
    Map<String, List<ImportPendingReference>> pendingRelations = const {},
    this.compiledTemplate,
  }) : changes = List.unmodifiable(changes),
       values = ImportItemInput('', '', const [], values: values).values,
       pendingRelations = ImportItemInput(
         '',
         '',
         const [],
         pendingRelations: pendingRelations,
       ).pendingRelations,
       relations = relations == null && pendingRelations.isEmpty
           ? null
           : ImportItemInput(
               '',
               '',
               const [],
               relations: relations ?? const {},
             ).relations;
  final String itemId;
  final int baseVersion;
  final List<FieldChange> changes;
  final String? name, description;
  final String? templateId, templateVersion, templateDigest;
  final Map<String, Object?> values;
  final Map<String, List<InformationRelationRef>>? relations;
  final Map<String, List<ImportPendingReference>> pendingRelations;

  /// Validated private snapshot, never accepted from Agent JSON.
  final ImportItemInput? compiledTemplate;
  Map<String, Object?> get submissionJson => {
    'itemId': itemId,
    'baseVersion': baseVersion,
    'changes': changes.map((c) => c.toJson()).toList(),
    if (name != null) 'name': name,
    if (description != null) 'description': description,
    if (templateId != null) ...{
      'templateId': templateId,
      'templateVersion': templateVersion,
      'templateDigest': templateDigest,
      'values': values,
      if (relations != null)
        'relations': ImportItemInput(
          '',
          '',
          const [],
          relations: relations!,
          pendingRelations: pendingRelations,
        ).relationJson,
    },
  };
  Map<String, Object?> toJson() => {
    ...submissionJson,
    if (compiledTemplate != null)
      'compiledTemplate': compiledTemplate!.toJson(),
  };
  factory UpdateInput.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
      (key) => !const {
        'itemId',
        'baseVersion',
        'changes',
        'name',
        'description',
        'templateId',
        'templateVersion',
        'templateDigest',
        'values',
        'relations',
      }.contains(key),
    )) {
      throw const FormatException('Agent cannot supply compiled template');
    }
    return UpdateInput._read(json, private: false);
  }
  factory UpdateInput.fromPrivateJson(Map<String, dynamic> json) =>
      UpdateInput._read(json, private: true);
  factory UpdateInput._read(
    Map<String, dynamic> json, {
    required bool private,
  }) => UpdateInput(
    json['itemId'] as String,
    json['baseVersion'] as int,
    (json['changes'] as List? ?? []).map(
      (dynamic c) => FieldChange.fromJson(c as Map<String, dynamic>),
    ),
    name: json['name'] as String?,
    description: json['description'] as String?,
    templateId: json['templateId'] as String?,
    templateVersion: json['templateVersion'] as String?,
    templateDigest: json['templateDigest'] as String?,
    values: Map<String, Object?>.from(json['values'] as Map? ?? {}),
    relations: json.containsKey('relations')
        ? importRelationsFromJson(json['relations'])
        : null,
    pendingRelations: importPendingRelationsFromJson(json['relations']),
    compiledTemplate: private && json['compiledTemplate'] != null
        ? ImportItemInput.fromPrivateJson(
            Map<String, dynamic>.from(json['compiledTemplate'] as Map),
          )
        : null,
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
    this.approvedReview,
  });
  final String id, sessionBinding, chatLabel;
  final DateTime createdAt;
  final UpdateInput input;
  final UpdateProposalState state;
  final int version;
  final UpdateReceipt? result;
  final UpdateReview? approvedReview;
  bool get approved => approvedReview != null;
  UpdateProposal approve(UpdateReview review) => UpdateProposal(
    id: id,
    sessionBinding: sessionBinding,
    chatLabel: chatLabel,
    createdAt: createdAt,
    input: review.input,
    state: state,
    version: version + 1,
    approvedReview: review,
  );
  UpdateProposal finish(
    UpdateProposalState state, {
    UpdateReceipt? result,
    int? resultingVersion,
  }) => UpdateProposal(
    id: id,
    sessionBinding: sessionBinding,
    chatLabel: chatLabel,
    createdAt: createdAt,
    input: UpdateInput(input.itemId, input.baseVersion, const []),
    state: state,
    version: resultingVersion ?? version + 1,
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
    if (approvedReview case final review?)
      'approval': {
        'directoryId': review.directoryId,
        'tagIds': review.tagIds,
        'fieldDescriptions': review.fieldDescriptions,
      },
    if (result != null)
      'result': {'itemId': result!.itemId, 'version': result!.version},
  };
  factory UpdateProposal.fromJson(Map<String, dynamic> json) => UpdateProposal(
    id: json['id'] as String,
    sessionBinding: json['sessionBinding'] as String,
    chatLabel: json['chatLabel'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    input: UpdateInput.fromPrivateJson(json['input'] as Map<String, dynamic>),
    state: UpdateProposalState.values.byName(json['state'] as String),
    version: json['version'] as int,
    approvedReview: json['approval'] == null
        ? null
        : UpdateReview(
            UpdateInput.fromPrivateJson(json['input'] as Map<String, dynamic>),
            directoryId: (json['approval'] as Map)['directoryId'] as String?,
            tagIds: ((json['approval'] as Map)['tagIds'] as List)
                .cast<String>(),
            fieldDescriptions: Map<String, String>.from(
              (json['approval'] as Map)['fieldDescriptions'] as Map,
            ),
          ),
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
