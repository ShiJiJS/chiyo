import 'workspace_source.dart';
import 'workspace_transport.dart';

Map<String, Object?> classificationChangeToJson(
  WorkspaceClassificationChange c,
) => {
  'operationId': c.operationId,
  'expectedVersion': c.expectedVersion,
  'kind': c.kind.name,
  'action': c.actionName,
  'targetId': c.targetId,
  'name': c.name,
  'parentId': c.parentId,
  'removalToken': c.removalToken,
};
WorkspaceClassificationChange classificationChangeFromJson(
  Map<String, dynamic> c,
) => decodeWorkspace(() {
  if (c.keys.any(
    (k) => !const {
      'operationId',
      'expectedVersion',
      'kind',
      'action',
      'targetId',
      'name',
      'parentId',
      'removalToken',
    }.contains(k),
  )) {
    throw const FormatException();
  }
  final kind = WorkspaceClassificationKind.values.byName(c['kind'] as String);
  if (kind == WorkspaceClassificationKind.directory) {
    if (c['removalToken'] != null) throw const FormatException();
    return WorkspaceDirectoryChange(
      operationId: c['operationId'] as String,
      expectedVersion: c['expectedVersion'] as int,
      action: WorkspaceDirectoryAction.values.byName(c['action'] as String),
      directoryId: c['targetId'] as String?,
      name: c['name'] as String,
      parentId: c['parentId'] as String?,
    );
  }
  if (c['parentId'] != null) throw const FormatException();
  return WorkspaceTagChange(
    operationId: c['operationId'] as String,
    expectedVersion: c['expectedVersion'] as int,
    action: WorkspaceTagAction.values.byName(c['action'] as String),
    tagId: c['targetId'] as String?,
    name: c['name'] as String,
    removalToken: c['removalToken'] as String?,
  );
});
Map<String, Object?> _directory(WorkspaceDirectory d) => {
  'id': d.id,
  'name': d.name,
  'parentId': d.parentId,
  'proposed': d.proposed,
};
WorkspaceDirectory _readDirectory(Object? value) {
  final d = workspaceObject(value);
  return WorkspaceDirectory(
    d['id'] as String,
    d['name'] as String,
    parentId: d['parentId'] as String?,
    proposed: d['proposed'] as bool,
  );
}

Map<String, Object?> classificationReceiptToJson(
  WorkspaceClassificationReceipt r,
) => {
  'operationId': r.operationId,
  'commandDigest': r.commandDigest,
  'expectedVersion': r.expectedVersion,
  'version': r.version,
  'targetId': r.targetId,
  'directory': r.directory == null ? null : _directory(r.directory!),
  'tag': r.tag == null ? null : workspaceTagToJson(r.tag!),
};
WorkspaceClassificationReceipt classificationReceiptFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      return WorkspaceClassificationReceipt(
        operationId: r['operationId'] as String,
        commandDigest: r['commandDigest'] as String,
        expectedVersion: r['expectedVersion'] as int,
        version: r['version'] as int,
        targetId: r['targetId'] as String,
        directory: r['directory'] == null
            ? null
            : _readDirectory(r['directory']),
        tag: r['tag'] == null ? null : workspaceTagFromJson(r['tag']),
      );
    });
Map<String, Object?> tagRemovalToJson(WorkspaceTagRemovalPreview p) => {
  'token': p.token,
  'tagId': p.tagId,
  'catalogVersion': p.catalogVersion,
  'affectedCount': p.affectedCount,
};
WorkspaceTagRemovalPreview tagRemovalFromJson(Object? value) =>
    decodeWorkspace(() {
      final p = workspaceObject(value);
      return WorkspaceTagRemovalPreview(
        token: p['token'] as String,
        tagId: p['tagId'] as String,
        catalogVersion: p['catalogVersion'] as int,
        affectedCount: p['affectedCount'] as int,
      );
    });

WorkspaceLibrarySelection librarySelectionFromJson(Object? value) =>
    decodeWorkspace(() {
      final s = workspaceObject(value);
      if (s.length != 3 ||
          s.keys.any(
            (k) => !const {
              'directories',
              'information',
              'credentials',
            }.contains(k),
          )) {
        throw const FormatException();
      }
      final directories = (s['directories'] as List).cast<String>(),
          info = (s['information'] as List).cast<String>(),
          credentials = (s['credentials'] as List).cast<String>();
      for (final ids in [directories, info, credentials]) {
        if (ids.toSet().length != ids.length) throw const FormatException();
      }
      return WorkspaceLibrarySelection(
        directoryIds: directories,
        records: [
          for (final id in info)
            WorkspaceRecordRef(WorkspaceRecordKind.information, id),
          for (final id in credentials)
            WorkspaceRecordRef(WorkspaceRecordKind.credential, id),
        ],
      );
    });
WorkspaceLibraryPosition? libraryPositionFromJson(Object? value) =>
    decodeWorkspace(() {
      if (value == null) return null;
      final p = workspaceObject(value);
      final anchor = p['anchor'] as List;
      if (p.length != 2 || anchor.length != 2 || p['after'] is! bool) {
        throw const FormatException();
      }
      final kind = anchor[0] as String,
          id = anchor[1] as String,
          after = p['after'] as bool;
      if (kind == 'directory') {
        return WorkspaceLibraryPosition.directory(id, after: after);
      }
      return WorkspaceLibraryPosition.record(
        WorkspaceRecordRef(WorkspaceRecordKind.values.byName(kind), id),
        after: after,
      );
    });
Map<String, Object?> _record(WorkspaceLibraryRecycleRecord r) => {
  'ref': recordRefToJson(r.ref),
  'name': r.name,
  'type': r.type,
  'directoryId': r.directoryId,
  'path': r.path,
  if (r.recycleEntryId != null) 'recycleEntryId': r.recycleEntryId,
};
WorkspaceLibraryRecycleRecord _readRecord(Object? value) {
  final r = workspaceObject(value);
  return WorkspaceLibraryRecycleRecord(
    ref: recordRefFromJson(r['ref']),
    name: r['name'] as String,
    type: r['type'] as String,
    directoryId: r['directoryId'] as String?,
    path: (r['path'] as List).cast<String>(),
    recycleEntryId: r['recycleEntryId'] as String?,
  );
}

Map<String, Object?> libraryScopeToJson(WorkspaceLibraryRecyclePreview p) => {
  'token': p.token,
  'directories': p.directories.map(_directory).toList(),
  'paths': p.paths,
  'records': p.records.map(_record).toList(),
  'roots': p.roots,
  'warnings': p.warnings,
  'conflicts': p.conflicts,
};
WorkspaceLibraryRecyclePreview libraryScopeFromJson(Object? value) {
  final p = workspaceObject(value);
  return WorkspaceLibraryRecyclePreview(
    token: p['token'] as String,
    directories: (p['directories'] as List).map(_readDirectory),
    paths: {
      for (final e in workspaceObject(p['paths']).entries)
        e.key: (e.value as List).cast<String>(),
    },
    records: (p['records'] as List).map(_readRecord),
    roots: (p['roots'] as List).cast<String>(),
    warnings: (p['warnings'] as List).cast<String>(),
    conflicts: (p['conflicts'] as List).cast<String>(),
  );
}

Map<String, Object?> libraryMovePreviewToJson(WorkspaceLibraryMovePreview p) =>
    {
      'wireVersion': 1,
      'scope': libraryScopeToJson(p.scope),
      'token': p.token,
      'targetId': p.targetId,
      'targetPath': p.targetPath,
      'roots': p.roots,
      'records': p.records.map(_record).toList(),
      'conflicts': p.conflicts,
      'position': p.position?.toJson(),
      'anchorName': p.anchorName,
    };
WorkspaceLibraryMovePreview libraryMovePreviewFromJson(Object? value) =>
    decodeWorkspace(() {
      final p = workspaceObject(value);
      if (p['wireVersion'] != 1) throw const FormatException();
      return WorkspaceLibraryMovePreview(
        scope: libraryScopeFromJson(p['scope']),
        token: p['token'] as String,
        targetId: p['targetId'] as String?,
        targetPath: (p['targetPath'] as List).cast<String>(),
        roots: (p['roots'] as List).cast<String>(),
        records: (p['records'] as List).map(_readRecord),
        conflicts: (p['conflicts'] as List).cast<String>(),
        position: libraryPositionFromJson(p['position']),
        anchorName: p['anchorName'] as String?,
      );
    });
Map<String, Object?> libraryMoveCommandToJson(WorkspaceLibraryMoveCommand c) =>
    {
      'operationId': c.operationId,
      'selection': c.selection.toJson(),
      'targetId': c.targetId,
      'reviewToken': c.reviewToken,
      'position': c.position?.toJson(),
    };
WorkspaceLibraryMoveCommand libraryMoveCommandFromJson(
  Map<String, dynamic> c,
) => decodeWorkspace(() {
  if (c.keys.any(
    (k) => !const {
      'operationId',
      'selection',
      'targetId',
      'reviewToken',
      'position',
    }.contains(k),
  )) {
    throw const FormatException();
  }
  return WorkspaceLibraryMoveCommand(
    operationId: c['operationId'] as String,
    selection: librarySelectionFromJson(c['selection']),
    targetId: c['targetId'] as String?,
    reviewToken: c['reviewToken'] as String,
    position: libraryPositionFromJson(c['position']),
  );
});
Map<String, Object?> libraryMoveReceiptToJson(WorkspaceLibraryMoveReceipt r) =>
    {
      'operationId': r.operationId,
      'inputHash': r.inputHash,
      'targetId': r.targetId,
    };
WorkspaceLibraryMoveReceipt libraryMoveReceiptFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      return WorkspaceLibraryMoveReceipt(
        operationId: r['operationId'] as String,
        inputHash: r['inputHash'] as String,
        targetId: r['targetId'] as String?,
      );
    });
Map<String, Object?> libraryPlacementTargetToJson(
  WorkspaceLibraryPlacementTarget t,
) => {
  'kind': t.kind,
  'id': t.id,
  'name': t.name,
  'type': t.type,
  'path': t.path,
  'directoryId': t.directoryId,
};
WorkspaceLibraryPlacementTarget libraryPlacementTargetFromJson(Object? value) {
  final t = workspaceObject(value);
  return WorkspaceLibraryPlacementTarget(
    kind: t['kind'] as String,
    id: t['id'] as String,
    name: t['name'] as String,
    type: t['type'] as String,
    path: t['path'] as String,
    directoryId: t['directoryId'] as String?,
  );
}
