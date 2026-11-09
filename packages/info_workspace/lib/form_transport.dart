import 'workspace_records.dart';
import 'workspace_transport.dart';
import 'workspace_legacy_templates.dart';

/// Owner form input carries only opaque file selections, never stage paths.
Map<String, Object?> workspaceCreateToJson(WorkspaceCreate c) => {
  'operationId': c.operationId,
  'typeId': c.typeId,
  'name': c.name,
  'description': c.description,
  'directoryId': c.directoryId,
  'tagIds': c.tagIds,
  'values': c.values,
  'relations': {
    for (final e in c.relations.entries)
      e.key: e.value.map(recordRefToJson).toList(),
  },
  'fileSelections': c.fileSelections,
  'expectedTemplateVersion': c.expectedTemplateVersion,
  'expectedTemplateDigest': c.expectedTemplateDigest,
  'legacyTemplateId': c.legacyTemplateId,
  'expectedLegacyVersion': c.expectedLegacyVersion,
};

WorkspaceCreate workspaceCreateFromJson(Object? value) => decodeWorkspace(() {
  final v = workspaceObject(value);
  if (v.length != 13 ||
      v.keys.any(
        (k) => !const {
          'operationId',
          'typeId',
          'name',
          'description',
          'directoryId',
          'tagIds',
          'values',
          'relations',
          'fileSelections',
          'expectedTemplateVersion',
          'expectedTemplateDigest',
          'legacyTemplateId',
          'expectedLegacyVersion',
        }.contains(k),
      )) {
    throw const FormatException();
  }
  return WorkspaceCreate(
    operationId: v['operationId'] as String,
    typeId: v['typeId'] as String,
    name: v['name'] as String,
    description: v['description'] as String,
    directoryId: v['directoryId'] as String?,
    tagIds: (v['tagIds'] as List).cast<String>(),
    values: workspaceObject(v['values']),
    relations: {
      for (final e in workspaceObject(v['relations']).entries)
        e.key: (e.value as List).map(recordRefFromJson).toList(),
    },
    fileSelections: workspaceObject(v['fileSelections']).cast<String, String>(),
    expectedTemplateVersion: v['expectedTemplateVersion'] as String?,
    expectedTemplateDigest: v['expectedTemplateDigest'] as String?,
    legacyTemplateId: v['legacyTemplateId'] as String?,
    expectedLegacyVersion: v['expectedLegacyVersion'] as int?,
  );
});

Map<String, Object?> legacyTemplateToJson(WorkspaceLegacyTemplate t) => {
  'id': t.id,
  'name': t.name,
  'description': t.description,
  'version': t.version,
  'definition': t.definition,
  'packageId': t.packageId,
  'conversionProblem': t.conversionProblem,
  'fields': [
    for (final f in t.fields)
      {
        'id': f.id,
        'name': f.name,
        'description': f.description,
        'kind': f.kind.name,
      },
  ],
};
WorkspaceLegacyTemplate legacyTemplateFromJson(Object? value) =>
    decodeWorkspace(() {
      final v = workspaceObject(value);
      return WorkspaceLegacyTemplate(
        id: v['id'] as String,
        name: v['name'] as String,
        description: v['description'] as String,
        version: v['version'] as int,
        definition: workspaceObject(v['definition']),
        packageId: v['packageId'] as String,
        conversionProblem: v['conversionProblem'] as String?,
        fields: [
          for (final raw in v['fields'] as List)
            (() {
              final f = workspaceObject(raw);
              return WorkspaceLegacyField(
                f['id'] as String,
                f['name'] as String,
                f['description'] as String,
                WorkspaceLegacyFieldKind.values.byName(f['kind'] as String),
              );
            })(),
        ],
      );
    });
