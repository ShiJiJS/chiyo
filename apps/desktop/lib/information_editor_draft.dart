import 'package:info_core/info_core.dart';

/// Text and file selections remain separate. No source path or file body is
/// retained by the UI draft; a file holds a stage or an unchanged version.
class EditableInformationField {
  EditableInformationField({
    this.original,
    String? name,
    String? description,
    String? value,
    FieldKind? kind,
    this.replaceIdentity = false,
  }) : name = name ?? original?.name ?? '',
       description = description ?? original?.description ?? '',
       value =
           value ??
           (original == null || original.kind == FieldKind.file
               ? ''
               : original.value),
       kind = kind ?? original?.kind ?? FieldKind.structured;
  final InformationField? original;
  final bool replaceIdentity;
  String name, description, value;
  FieldKind kind;
  InformationFileStage? stage;
  InformationAttachmentRef? get retainedFile =>
      kind == FieldKind.file ? original?.attachment : null;
  bool get hasFile => stage != null || retainedFile != null;
  bool get replacesIdentity =>
      original != null &&
      (replaceIdentity ||
          name.trim() != original!.name ||
          kind != original!.kind);
  FieldInput get input => kind == FieldKind.file
      ? FieldInput.file(
          name,
          description,
          retainedFile ?? (throw const AccessFailure('unsupported_file_write')),
        )
      : FieldInput(name, description, value, kind: kind);
  InformationDraftField get completeField => kind != FieldKind.file
      ? InformationDraftField.text(
          name,
          description,
          value,
          fieldId: original?.id,
          kind: kind,
          replaceIdentity: replaceIdentity,
        )
      : stage != null
      ? InformationDraftField.stagedFile(
          name,
          description,
          stage!.id,
          fieldId: original?.id,
          replaceIdentity: replaceIdentity,
        )
      : InformationDraftField.retainedFile(
          name,
          description,
          retainedFile ?? (throw const AccessFailure('stage_unavailable')),
          fieldId: original?.id,
          replaceIdentity: replaceIdentity,
        );
}

class InformationEditorDraft {
  InformationEditorDraft({
    this.original,
    String? name,
    String? description,
    String? directoryId,
    Iterable<String>? tagIds,
    this.suggestedDirectory = '',
    Iterable<String> suggestedTags = const [],
    List<EditableInformationField>? fields,
  }) : name = name ?? original?.name ?? '',
       description = description ?? original?.description ?? '',
       directoryId = directoryId ?? original?.directoryId,
       tagIds = {...?tagIds ?? original?.tagIds},
       suggestedTags = {...suggestedTags},
       fields =
           fields ??
           (original?.fields
                   .map((f) => EditableInformationField(original: f))
                   .toList() ??
               [EditableInformationField()]);
  final InformationItem? original;
  String name, description;
  String? directoryId;
  final Set<String> tagIds;
  String suggestedDirectory;
  final Set<String> suggestedTags;
  final List<EditableInformationField> fields;
  int get destructiveChanges =>
      (original?.fields
              .where((old) => !fields.any((f) => f.original?.id == old.id))
              .length ??
          0) +
      fields.where((f) => f.replacesIdentity).length;
  List<FieldChange> get changes => [
    for (final old in original?.fields ?? <InformationField>[])
      if (!fields.any((f) => f.original?.id == old.id))
        FieldChange.remove(old.id),
    for (final field in fields)
      if (field.original == null)
        FieldChange.add(field.input)
      else if (field.replacesIdentity)
        FieldChange.replace(field.original!.id, field.input)
      else if (field.kind != FieldKind.file &&
          field.value != field.original!.value)
        FieldChange.correct(field.original!.id, field.value),
  ];
  Map<String, String> get fieldDescriptions => {
    for (final f in fields)
      if (f.original != null &&
          !f.replacesIdentity &&
          f.description != f.original!.description)
        f.original!.id: f.description,
  };
  InformationDraftInput get completeInput => InformationDraftInput(
    name: name,
    description: description,
    itemId: original?.id,
    baseVersion: original?.version,
    directoryId: directoryId,
    tagIds: tagIds,
    fields: fields.map((f) => f.completeField),
  );
  void applyTemplate(InformationTemplate template) {
    name = name.isEmpty ? template.name : name;
    description = template.description;
    fields
      ..clear()
      ..addAll(
        template.fields.map(
          (f) => EditableInformationField(
            name: f.name,
            description: f.description,
            kind: f.kind,
          ),
        ),
      );
  }
}
