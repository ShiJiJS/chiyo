import 'info_core.dart';

/// Owner-only wire representation of an ordinary text save. Layout and field
/// identities use the existing model parsers, rather than a second UI schema.
/// New file bytes require the separate staged transfer protocol.
InformationDraftInput informationDraftFromJson(Map<String, dynamic> value) {
  try {
    if (value.keys.any(
      (k) => !const {
        'name',
        'description',
        'fields',
        'itemId',
        'baseVersion',
        'directoryId',
        'tagIds',
        'layout',
        'command',
      }.contains(k),
    )) {
      throw const FormatException('Unsupported draft member');
    }
    final rawLayout = value['layout'] as Map<String, dynamic>?;
    if (rawLayout != null &&
        rawLayout.keys.any((k) => !const {'layout', 'fieldKeys'}.contains(k))) {
      throw const FormatException('Unsupported layout member');
    }
    return InformationDraftInput(
      name: value['name'] as String,
      description: value['description'] as String,
      itemId: value['itemId'] as String?,
      baseVersion: value['baseVersion'] as int?,
      directoryId: value['directoryId'] as String?,
      tagIds: (value['tagIds'] as List? ?? []).cast<String>(),
      command: value['command'] == null
          ? null
          : InformationRecordCommand.fromJson(
              value['command'] as Map<String, dynamic>,
            ),
      layout: rawLayout == null
          ? null
          : InformationDraftLayout(
              InformationLayout.fromJson(
                rawLayout['layout'] as Map<String, dynamic>,
              ),
              (rawLayout['fieldKeys'] as List).cast<String?>(),
            ),
      fields: (value['fields'] as List).map((raw) {
        final field = raw as Map<String, dynamic>;
        if (field.keys.any(
          (k) => !const {
            'name',
            'description',
            'text',
            'fieldId',
            'kind',
            'replaceIdentity',
          }.contains(k),
        )) {
          throw const FormatException('Unsupported field member');
        }
        final kind = FieldKind.values.byName(
          field['kind'] as String? ?? 'structured',
        );
        if (kind == FieldKind.file) {
          throw const FormatException('Files require staged transport');
        }
        return InformationDraftField.text(
          field['name'] as String,
          field['description'] as String,
          field['text'] as String,
          fieldId: field['fieldId'] as String?,
          kind: kind,
          replaceIdentity: field['replaceIdentity'] as bool? ?? false,
        );
      }),
    );
  } on ArgumentError {
    throw const FormatException('Invalid draft');
  } on TypeError {
    throw const FormatException('Invalid draft');
  }
}
