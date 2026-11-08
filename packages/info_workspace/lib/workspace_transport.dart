import 'workspace_records.dart';
import 'workspace_history.dart';

/// Owner-only workspace data. Agent endpoints use their separate core protocol.
/// Definitions, field identities and order are preserved, not reconstructed.
T decodeWorkspace<T>(T Function() read) {
  try {
    return read();
  } on Object {
    throw const FormatException('Invalid workspace data');
  }
}

Map<String, dynamic> workspaceObject(Object? value) =>
    Map<String, dynamic>.from(value as Map);
Map<String, Object?> recordRefToJson(WorkspaceRecordRef r) => {
  'kind': r.kind.name,
  'id': r.id,
};
WorkspaceRecordRef recordRefFromJson(Object? value) => decodeWorkspace(() {
  final r = workspaceObject(value);
  final id = r['id'] as String;
  if (r.length != 2 || id.isEmpty || id.length > 4096) {
    throw const FormatException();
  }
  return WorkspaceRecordRef(
    WorkspaceRecordKind.values.byName(r['kind'] as String),
    id,
  );
});
Map<String, Object?> workspaceTypeToJson(WorkspaceType t) => {
  'id': t.id,
  'name': t.name,
  'icon': t.icon,
};
WorkspaceType workspaceTypeFromJson(Object? value) {
  final t = workspaceObject(value);
  return WorkspaceType(
    t['id'] as String,
    t['name'] as String,
    t['icon'] as String,
  );
}

Map<String, Object?> workspaceTagToJson(WorkspaceTag t) => {
  'id': t.id,
  'name': t.name,
};
WorkspaceTag workspaceTagFromJson(Object? value) {
  final t = workspaceObject(value);
  return WorkspaceTag(t['id'] as String, t['name'] as String);
}

Map<String, Object?> recordSummaryToJson(WorkspaceRecordSummary r) => {
  'ref': recordRefToJson(r.ref),
  'name': r.name,
  'description': r.description,
  'type': workspaceTypeToJson(r.type),
  'updatedAt': r.updatedAt.toIso8601String(),
  'directoryId': r.directoryId,
  'tags': r.tags.map(workspaceTagToJson).toList(),
};
WorkspaceRecordSummary recordSummaryFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      return WorkspaceRecordSummary(
        ref: recordRefFromJson(r['ref']),
        name: r['name'] as String,
        description: r['description'] as String,
        type: workspaceTypeFromJson(r['type']),
        updatedAt: DateTime.parse(r['updatedAt'] as String),
        directoryId: r['directoryId'] as String?,
        tags: (r['tags'] as List).map(workspaceTagFromJson),
      );
    });
Map<String, Object?> workspaceRelationsToJson(
  Map<String, List<WorkspaceRecordRef>> relations,
) => {
  for (final e in relations.entries)
    e.key: e.value.map(recordRefToJson).toList(),
};
Map<String, List<WorkspaceRecordRef>> workspaceRelationsFromJson(
  Object? value,
) => {
  for (final e in workspaceObject(value).entries)
    e.key: (e.value as List).map(recordRefFromJson).toList(),
};

Map<String, Object?> workspaceDetailToJson(WorkspaceDetail d) {
  if (d.record.ref.kind == WorkspaceRecordKind.credential &&
      d.values.isNotEmpty) {
    throw const FormatException('Credential material is not workspace data');
  }
  return {
    'wireVersion': 1,
    'record': recordSummaryToJson(d.record),
    'version': d.version,
    'templateState': d.templateState.name,
    'definition': d.definition,
    'values': d.values,
    'relations': workspaceRelationsToJson(d.relations),
    'incomingRelations': workspaceRelationsToJson(d.incomingRelations),
    'fieldIds': d.fieldIds,
    'fieldOverrides': d.fieldOverrides,
    'retainedFields': d.retainedFields,
    'retainedRelations': d.retainedRelations,
  };
}

WorkspaceDetail workspaceDetailFromJson(Object? value) => decodeWorkspace(() {
  final d = workspaceObject(value);
  if (d['wireVersion'] != 1) throw const FormatException();
  final result = WorkspaceDetail(
    record: recordSummaryFromJson(d['record']),
    version: d['version'] as int,
    templateState: WorkspaceTemplateState.values.byName(
      d['templateState'] as String,
    ),
    definition: workspaceObject(d['definition']),
    values: workspaceObject(d['values']),
    relations: workspaceRelationsFromJson(d['relations']),
    incomingRelations: workspaceRelationsFromJson(d['incomingRelations']),
    fieldIds: workspaceObject(d['fieldIds']).cast<String, String>(),
    fieldOverrides: {
      for (final e in workspaceObject(d['fieldOverrides']).entries)
        e.key: e.value == null ? null : workspaceObject(e.value),
    },
    retainedFields: (d['retainedFields'] as List).map(workspaceObject),
    retainedRelations: (d['retainedRelations'] as List).map(workspaceObject),
  );
  workspaceDetailToJson(
    result,
  ); // Enforce the same credential exclusion on input.
  return result;
});

Map<String, Object?> workspaceCatalogToJson(WorkspaceCatalog c) => {
  'wireVersion': 1,
  'version': c.version,
  'recycledCount': c.recycledCount,
  'directories': [
    for (final d in c.directories)
      {
        'id': d.id,
        'name': d.name,
        'parentId': d.parentId,
        'proposed': d.proposed,
      },
  ],
  'tags': c.tags.map(workspaceTagToJson).toList(),
  'types': c.types.map(workspaceTypeToJson).toList(),
  'creatableTypes': c.creatableTypes.map(workspaceTypeToJson).toList(),
  'directoryCounts': c.directoryCounts,
  'tagCounts': c.tagCounts,
};
WorkspaceCatalog workspaceCatalogFromJson(Object? value) => decodeWorkspace(() {
  final c = workspaceObject(value);
  if (c['wireVersion'] != 1) throw const FormatException();
  return WorkspaceCatalog(
    version: c['version'] as int,
    recycledCount: c['recycledCount'] as int,
    directories: [
      for (final d in c['directories'] as List)
        WorkspaceDirectory(
          d['id'] as String,
          d['name'] as String,
          parentId: d['parentId'] as String?,
          proposed: d['proposed'] as bool,
        ),
    ],
    tags: (c['tags'] as List).map(workspaceTagFromJson),
    types: (c['types'] as List).map(workspaceTypeFromJson),
    creatableTypes: (c['creatableTypes'] as List).map(workspaceTypeFromJson),
    directoryCounts: workspaceObject(c['directoryCounts']).cast<String, int>(),
    tagCounts: workspaceObject(c['tagCounts']).cast<String, int>(),
  );
});

Map<String, Object?> workspaceResultsToJson(WorkspaceResults r) => {
  'items': r.items.map(recordSummaryToJson).toList(),
  'total': r.total,
  'offset': r.offset,
  'selection': r.selection == null ? null : recordRefToJson(r.selection!),
  'selectionIndex': r.selectionIndex,
  'groupCounts': r.groupCounts,
};
WorkspaceResults workspaceResultsFromJson(Object? value) => decodeWorkspace(() {
  final r = workspaceObject(value);
  return WorkspaceResults(
    items: (r['items'] as List).map(recordSummaryFromJson),
    total: r['total'] as int,
    offset: r['offset'] as int,
    selection: r['selection'] == null
        ? null
        : recordRefFromJson(r['selection']),
    selectionIndex: r['selectionIndex'] as int?,
    groupCounts: workspaceObject(r['groupCounts']).cast<String, int>(),
  );
});

Map<String, Object?> relationQueryToJson(WorkspaceRelationQuery q) => {
  'typeId': q.typeId,
  'key': q.key,
  'source': q.source == null ? null : recordRefToJson(q.source!),
  'keyword': q.keyword,
  'offset': q.offset,
  'limit': q.limit,
};
WorkspaceRelationQuery relationQueryFromJson(Object? value) =>
    decodeWorkspace(() {
      final q = workspaceObject(value);
      return WorkspaceRelationQuery(
        typeId: q['typeId'] as String,
        key: q['key'] as String,
        source: q['source'] == null ? null : recordRefFromJson(q['source']),
        keyword: q['keyword'] as String,
        offset: q['offset'] as int,
        limit: q['limit'] as int,
      );
    });

Map<String, Object?> workspaceArchiveToJson(WorkspaceArchive a) => {
  'wireVersion': 1,
  'detail': workspaceDetailToJson(a.detail),
  'archivedAt': a.archivedAt.toIso8601String(),
  'directoryName': a.directoryName,
  'wholeItem': a.wholeItem,
  'targets': [
    for (final e in a.targets.entries)
      {'ref': recordRefToJson(e.key), 'summary': recordSummaryToJson(e.value)},
  ],
};
WorkspaceArchive workspaceArchiveFromJson(Object? value) => decodeWorkspace(() {
  final a = workspaceObject(value);
  if (a['wireVersion'] != 1) throw const FormatException();
  return WorkspaceArchive(
    detail: workspaceDetailFromJson(a['detail']),
    archivedAt: DateTime.parse(a['archivedAt'] as String),
    directoryName: a['directoryName'] as String?,
    wholeItem: a['wholeItem'] as bool,
    targets: {
      for (final t in a['targets'] as List)
        recordRefFromJson(t['ref']): recordSummaryFromJson(t['summary']),
    },
  );
});
