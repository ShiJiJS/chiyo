import 'workspace_source.dart';
import 'workspace_transport.dart';
import 'library_transport.dart';
import 'credential_transport.dart';

part 'grant_history_transport.dart';

Map<String, dynamic> historyWire(Object? raw, List<String> keys) {
  final v = workspaceObject(raw);
  if (v.length != keys.length || keys.any((k) => !v.containsKey(k))) {
    throw const FormatException('Invalid history fields');
  }
  return v;
}

Map<String, dynamic> historyEnvelope(Object? raw, List<String> keys) {
  final v = historyWire(raw, ['wireVersion', ...keys]);
  if (v['wireVersion'] != 1) {
    throw const FormatException('Invalid history version');
  }
  return v;
}

String historyText(Object? v, {int max = 4096, bool empty = false}) {
  if (v is! String || (!empty && v.isEmpty) || v.length > max) {
    throw const FormatException('Invalid history text');
  }
  return v;
}

int historyInt(Object? v, {int min = 0, int max = 1000000}) {
  if (v is! int || v < min || v > max) {
    throw const FormatException('Invalid history count');
  }
  return v;
}

List<dynamic> _list(Object? v, {int max = 100000}) {
  if (v is! List || v.length > max) {
    throw const FormatException('Invalid history list');
  }
  return v;
}

List<String> _texts(Object? v) =>
    _list(v).map((s) => historyText(s, max: 200000, empty: true)).toList();
String? _optionalText(Object? v) => v == null ? null : historyText(v);
int? _optionalInt(Object? v, {int min = 1}) =>
    v == null ? null : historyInt(v, min: min);
DateTime _date(Object? v) => DateTime.parse(historyText(v, max: 50)).toUtc();
DateTime? _optionalDate(Object? v) => v == null ? null : _date(v);
bool _bool(Object? v) {
  if (v is! bool) throw const FormatException('Invalid history flag');
  return v;
}

String _hash(Object? v) {
  final s = historyText(v, max: 64);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) {
    throw const FormatException('Invalid history digest');
  }
  return s;
}

String _operation(Object? v) {
  final s = historyText(v, max: 128);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(s)) {
    throw const FormatException('Invalid history operation');
  }
  return s;
}

WorkspaceRecordSummary _summary(Object? v) {
  final r = historyWire(v, [
    'ref',
    'name',
    'description',
    'type',
    'updatedAt',
    'directoryId',
    'tags',
  ]);
  recordRefFromJson(r['ref']);
  historyText(r['name'], empty: true);
  historyText(r['description'], max: 200000, empty: true);
  final t = historyWire(r['type'], ['id', 'name', 'icon']);
  for (final x in t.values) {
    historyText(x, empty: true);
  }
  _date(r['updatedAt']);
  _optionalText(r['directoryId']);
  for (final v in _list(r['tags'])) {
    final t = historyWire(v, ['id', 'name']);
    historyText(t['id']);
    historyText(t['name'], empty: true);
  }
  return recordSummaryFromJson(r);
}

WorkspaceDetail _detail(Object? v) {
  final d = historyEnvelope(v, [
    'record',
    'version',
    'templateState',
    'definition',
    'values',
    'relations',
    'incomingRelations',
    'fieldIds',
    'fieldOverrides',
    'retainedFields',
    'retainedRelations',
  ]);
  _summary(d['record']);
  historyInt(d['version'], min: 1);
  return workspaceDetailFromJson(d);
}

WorkspaceArchive _archive(Object? v) {
  final a = historyEnvelope(v, [
    'detail',
    'archivedAt',
    'directoryName',
    'wholeItem',
    'targets',
  ]);
  _detail(a['detail']);
  _date(a['archivedAt']);
  _optionalText(a['directoryName']);
  _bool(a['wholeItem']);
  final targets = <WorkspaceRecordRef>{};
  for (final v in _list(a['targets'])) {
    final t = historyWire(v, ['ref', 'summary']);
    final ref = recordRefFromJson(t['ref']);
    if (_summary(t['summary']).ref != ref || !targets.add(ref)) {
      throw const FormatException('Invalid history target');
    }
  }
  return workspaceArchiveFromJson(a);
}

Map<String, Object?> revisionsToJson(List<WorkspaceRevision> values) => {
  'wireVersion': 1,
  'items': [
    for (final r in values)
      {
        'record': recordSummaryToJson(r.record),
        'version': r.version,
        'archivedAt': r.archivedAt.toUtc().toIso8601String(),
      },
  ],
};
List<WorkspaceRevision> revisionsFromJson(Object? raw) => decodeWorkspace(() {
  final v = historyEnvelope(raw, ['items']);
  return _list(v['items']).map((r) {
    final v = historyWire(r, ['record', 'version', 'archivedAt']);
    return WorkspaceRevision(
      _summary(v['record']),
      historyInt(v['version'], min: 1),
      _date(v['archivedAt']),
    );
  }).toList();
});
Map<String, Object?> revisionPreviewToJson(WorkspaceRevisionPreview p) => {
  'wireVersion': 1,
  'current': workspaceDetailToJson(p.current),
  'archive': workspaceArchiveToJson(p.archive),
  'restored': workspaceDetailToJson(p.restored),
  'catalogVersion': p.catalogVersion,
  'notices': p.notices,
  'missingFields': p.missingFields,
};
WorkspaceRevisionPreview revisionPreviewFromJson(Object? raw) =>
    decodeWorkspace(() {
      final p = historyEnvelope(raw, [
        'current',
        'archive',
        'restored',
        'catalogVersion',
        'notices',
        'missingFields',
      ]);
      final current = _detail(p['current']),
          archive = _archive(p['archive']),
          restored = _detail(p['restored']);
      if (current.record.ref != archive.detail.record.ref ||
          current.record.ref != restored.record.ref) {
        throw const FormatException('Mismatched history record');
      }
      return WorkspaceRevisionPreview(
        current: current,
        archive: archive,
        restored: restored,
        catalogVersion: historyInt(p['catalogVersion']),
        notices: _texts(p['notices']),
        missingFields: _texts(p['missingFields']),
      );
    });
Map<String, Object?> _entryToJson(WorkspaceRecycleEntry e) => {
  'id': e.id,
  'record': recordSummaryToJson(e.record),
  'version': e.version,
  'deletedAt': e.deletedAt.toUtc().toIso8601String(),
  'expiresAt': e.expiresAt.toUtc().toIso8601String(),
  'directoryName': e.directoryName,
  'wholeItem': e.wholeItem,
};
WorkspaceRecycleEntry _entry(Object? raw) {
  final e = historyWire(raw, [
    'id',
    'record',
    'version',
    'deletedAt',
    'expiresAt',
    'directoryName',
    'wholeItem',
  ]);
  return WorkspaceRecycleEntry(
    id: historyText(e['id']),
    record: _summary(e['record']),
    version: historyInt(e['version'], min: 1),
    deletedAt: _date(e['deletedAt']),
    expiresAt: _date(e['expiresAt']),
    directoryName: _optionalText(e['directoryName']),
    wholeItem: _bool(e['wholeItem']),
  );
}

Map<String, Object?> _batchToJson(WorkspaceDirectoryRecycleBatch b) => {
  'id': b.id,
  'deletedAt': b.deletedAt.toUtc().toIso8601String(),
  'expiresAt': b.expiresAt.toUtc().toIso8601String(),
  'directoryCount': b.directoryCount,
  'informationCount': b.informationCount,
  'credentialCount': b.credentialCount,
  'names': b.names,
};
WorkspaceDirectoryRecycleBatch _batch(Object? raw) {
  final b = historyWire(raw, [
    'id',
    'deletedAt',
    'expiresAt',
    'directoryCount',
    'informationCount',
    'credentialCount',
    'names',
  ]);
  return WorkspaceDirectoryRecycleBatch(
    id: historyText(b['id']),
    deletedAt: _date(b['deletedAt']),
    expiresAt: _date(b['expiresAt']),
    directoryCount: historyInt(b['directoryCount']),
    informationCount: historyInt(b['informationCount']),
    credentialCount: historyInt(b['credentialCount']),
    names: _texts(b['names']),
  );
}

Map<String, Object?> recycledResultsToJson(WorkspaceRecycleResults r) => {
  'wireVersion': 1,
  'total': r.total,
  'offset': r.offset,
  'rows': [
    for (final row in r.rows)
      row.entry != null
          ? {'entry': _entryToJson(row.entry!)}
          : {'batch': _batchToJson(row.batch!)},
  ],
};
WorkspaceRecycleResults recycledResultsFromJson(Object? raw) =>
    decodeWorkspace(() {
      final r = historyEnvelope(raw, ['total', 'offset', 'rows']);
      final rows = _list(r['rows'], max: 500).map((v) {
        final r = workspaceObject(v);
        if (r.length != 1) throw const FormatException();
        return r.containsKey('entry')
            ? WorkspaceRecycleRow.entry(_entry(r['entry']))
            : WorkspaceRecycleRow.batch(_batch(r['batch']));
      }).toList();
      final total = historyInt(r['total']), offset = historyInt(r['offset']);
      if (rows.length > total || offset > total) throw const FormatException();
      return WorkspaceRecycleResults(rows: rows, total: total, offset: offset);
    });
Map<String, Object?> recordChangeToJson(WorkspaceRecordChange c) => {
  'wireVersion': 1,
  'operationId': c.operationId,
  'ref': recordRefToJson(c.ref),
  'expectedVersion': c.expectedVersion,
  'action': c.action.name,
  'revisionVersion': c.revisionVersion,
  'entryId': c.entryId,
  'expectedCatalogVersion': c.expectedCatalogVersion,
  'expectedCurrentVersion': c.expectedCurrentVersion,
};
WorkspaceRecordChange recordChangeFromJson(Object? raw) => decodeWorkspace(() {
  final c = historyEnvelope(raw, [
    'operationId',
    'ref',
    'expectedVersion',
    'action',
    'revisionVersion',
    'entryId',
    'expectedCatalogVersion',
    'expectedCurrentVersion',
  ]);
  return WorkspaceRecordChange(
    operationId: _operation(c['operationId']),
    ref: recordRefFromJson(c['ref']),
    expectedVersion: historyInt(c['expectedVersion'], min: 1),
    action: WorkspaceRecordAction.values.byName(historyText(c['action'])),
    revisionVersion: _optionalInt(c['revisionVersion']),
    entryId: _optionalText(c['entryId']),
    expectedCatalogVersion: _optionalInt(c['expectedCatalogVersion'], min: 0),
    expectedCurrentVersion: _optionalInt(c['expectedCurrentVersion']),
  );
});
Map<String, Object?> recordReceiptToJson(WorkspaceRecordReceipt r) => {
  'ref': recordRefToJson(r.ref),
  'version': r.version,
  'entryId': r.entryId,
  'notices': r.notices,
};
WorkspaceRecordReceipt recordReceiptFromJson(Object? raw) =>
    decodeWorkspace(() {
      final r = historyWire(raw, ['ref', 'version', 'entryId', 'notices']);
      return WorkspaceRecordReceipt(
        ref: recordRefFromJson(r['ref']),
        version: historyInt(r['version'], min: 1),
        entryId: _optionalText(r['entryId']),
        notices: _texts(r['notices']),
      );
    });
Map<String, Object?> lifecycleReceiptToJson(WorkspaceOperationReceipt r) => {
  'wireVersion': 1,
  'operationId': r.operationId,
  'change': recordChangeToJson(
    WorkspaceRecordChange(
      operationId: r.operationId,
      ref: r.intent.ref!,
      expectedVersion: r.intent.expectedVersion!,
      action: WorkspaceRecordAction.values.byName(r.intent.kind.name),
      revisionVersion: r.intent.revisionVersion,
      entryId: r.intent.entryId,
      expectedCatalogVersion: r.intent.expectedCatalogVersion,
      expectedCurrentVersion: r.intent.expectedCurrentVersion,
    ),
  ),
  'result': recordReceiptToJson(r.result),
};
WorkspaceOperationReceipt lifecycleReceiptFromJson(Object? raw) =>
    decodeWorkspace(() {
      final r = historyEnvelope(raw, ['operationId', 'change', 'result']);
      final c = recordChangeFromJson(r['change']),
          result = recordReceiptFromJson(r['result']);
      if (_operation(r['operationId']) != c.operationId ||
          result.ref != c.ref) {
        throw const FormatException();
      }
      return WorkspaceOperationReceipt(
        operationId: c.operationId,
        intent: WorkspaceOperationIntent.change(c),
        result: result,
      );
    });
Map<String, Object?> batchOptionsToJson(WorkspaceLibraryRestoreOptions o) =>
    o.toJson();
WorkspaceLibraryRestoreOptions batchOptionsFromJson(Object? raw) =>
    decodeWorkspace(() {
      final o = historyWire(raw, ['names', 'parents']);
      final names = workspaceObject(o['names']),
          parents = workspaceObject(o['parents']);
      if (names.length > 100000 || parents.length > 100000) {
        throw const FormatException();
      }
      return WorkspaceLibraryRestoreOptions(
        names: {
          for (final e in names.entries)
            historyText(e.key): historyText(e.value),
        },
        parents: {
          for (final e in parents.entries)
            historyText(e.key): _optionalText(e.value),
        },
      );
    });
Map<String, Object?> batchChangeToJson(WorkspaceLibraryRecycleCommand c) => {
  'wireVersion': 1,
  'operationId': c.operationId,
  'reviewToken': c.reviewToken,
  'selection': c.selection?.toJson(),
  'batchId': c.batchId,
  'options': c.options.toJson(),
};
WorkspaceLibraryRecycleCommand batchChangeFromJson(Object? raw) =>
    decodeWorkspace(() {
      final c = historyEnvelope(raw, [
        'operationId',
        'reviewToken',
        'selection',
        'batchId',
        'options',
      ]);
      final id = _optionalText(c['batchId']),
          selection = c['selection'] == null
              ? null
              : librarySelectionFromJson(c['selection']),
          options = batchOptionsFromJson(c['options']);
      if ((id == null) == (selection == null) ||
          id == null &&
              (options.names.isNotEmpty || options.parents.isNotEmpty)) {
        throw const FormatException();
      }
      return WorkspaceLibraryRecycleCommand(
        operationId: _operation(c['operationId']),
        reviewToken: _hash(c['reviewToken']),
        selection: selection,
        batchId: id,
        options: options,
      );
    });
Map<String, Object?> batchReceiptToJson(WorkspaceLibraryRecycleReceipt r) => {
  'wireVersion': 1,
  'operationId': r.operationId,
  'inputHash': r.inputHash,
  'batchId': r.batchId,
  'restoring': r.restoring,
};
WorkspaceLibraryRecycleReceipt batchReceiptFromJson(Object? raw) =>
    decodeWorkspace(() {
      final r = historyEnvelope(raw, [
        'operationId',
        'inputHash',
        'batchId',
        'restoring',
      ]);
      return WorkspaceLibraryRecycleReceipt(
        operationId: _operation(r['operationId']),
        inputHash: _hash(r['inputHash']),
        batchId: historyText(r['batchId']),
        restoring: _bool(r['restoring']),
      );
    });
Map<String, Object?> batchPreviewToJson(WorkspaceLibraryRecyclePreview p) => {
  'wireVersion': 1,
  ...libraryScopeToJson(p),
};
WorkspaceLibraryRecyclePreview batchPreviewFromJson(Object? raw) =>
    decodeWorkspace(() {
      final p = historyEnvelope(raw, [
        'token',
        'directories',
        'paths',
        'records',
        'roots',
        'warnings',
        'conflicts',
      ]);
      _hash(p['token']);
      for (final raw in _list(p['directories'])) {
        final d = historyWire(raw, ['id', 'name', 'parentId', 'proposed']);
        historyText(d['id']);
        historyText(d['name']);
        _optionalText(d['parentId']);
        _bool(d['proposed']);
      }
      for (final raw in _list(p['records'])) {
        final fields = workspaceObject(raw);
        final r = historyWire(raw, [
          'ref',
          'name',
          'type',
          'directoryId',
          'path',
          if (fields.containsKey('recycleEntryId')) 'recycleEntryId',
        ]);
        recordRefFromJson(r['ref']);
        historyText(r['name']);
        historyText(r['type']);
        _optionalText(r['directoryId']);
        _optionalText(r['recycleEntryId']);
        _texts(r['path']);
      }
      final paths = workspaceObject(p['paths']);
      if (paths.length > 100000) throw const FormatException();
      for (final e in paths.entries) {
        historyText(e.key);
        _texts(e.value);
      }
      _texts(p['roots']);
      _texts(p['warnings']);
      _texts(p['conflicts']);
      return libraryScopeFromJson(p);
    });

WorkspaceArchive historyArchiveFromJson(Object? raw) =>
    decodeWorkspace(() => _archive(raw));

Map<String, Object?> credentialLifecycleToJson(WorkspaceCredentialChange c) => {
  'wireVersion': 1,
  'operationId': c.operationId,
  'ref': recordRefToJson(c.ref),
  'expectedRecordVersion': c.expectedRecordVersion,
  'expectedMaterialVersion': c.expectedMaterialVersion,
  'action': c.action.name,
  'materialVersion': c.materialVersion,
  'entryId': c.entryId,
  'expectedCatalogVersion': c.expectedCatalogVersion,
};
WorkspaceCredentialChange credentialLifecycleFromJson(
  Object? raw,
) => decodeWorkspace(() {
  final c = historyEnvelope(raw, [
    'operationId',
    'ref',
    'expectedRecordVersion',
    'expectedMaterialVersion',
    'action',
    'materialVersion',
    'entryId',
    'expectedCatalogVersion',
  ]);
  final ref = recordRefFromJson(c['ref']);
  if (ref.kind != WorkspaceRecordKind.credential) throw const FormatException();
  return WorkspaceCredentialChange(
    operationId: _operation(c['operationId']),
    ref: ref,
    expectedRecordVersion: historyInt(c['expectedRecordVersion'], min: 1),
    expectedMaterialVersion: historyInt(c['expectedMaterialVersion'], min: 1),
    action: WorkspaceCredentialAction.values.byName(historyText(c['action'])),
    materialVersion: _optionalInt(c['materialVersion']),
    entryId: _optionalText(c['entryId']),
    expectedCatalogVersion: _optionalInt(c['expectedCatalogVersion'], min: 0),
  );
});
Map<String, Object?> recycledCredentialToJson(WorkspaceCredentialRecycled r) =>
    {
      'wireVersion': 1,
      'entry': _entryToJson(r.entry),
      'detail': credentialDetailToJson(r.detail),
      'restored': credentialDetailToJson(r.restored),
      'catalogVersion': r.catalogVersion,
      'notices': r.notices,
    };
WorkspaceCredentialRecycled recycledCredentialFromJson(Object? raw) =>
    decodeWorkspace(() {
      final r = historyEnvelope(raw, [
        'entry',
        'detail',
        'restored',
        'catalogVersion',
        'notices',
      ]);
      final entry = _entry(r['entry']),
          detail = credentialDetailFromJson(r['detail']),
          restored = credentialDetailFromJson(r['restored']);
      historyWire(r['detail'], credentialDetailToJson(detail).keys.toList());
      historyWire(
        r['restored'],
        credentialDetailToJson(restored).keys.toList(),
      );
      if (entry.record.ref != detail.record.ref ||
          detail.record.ref != restored.record.ref ||
          restored.enabled) {
        throw const FormatException('Invalid recycled credential');
      }
      return WorkspaceCredentialRecycled(
        entry,
        detail,
        restored: restored,
        catalogVersion: historyInt(r['catalogVersion']),
        notices: _texts(r['notices']),
      );
    });
