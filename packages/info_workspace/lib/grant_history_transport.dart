part of 'history_transport.dart';

Map<String, Object?> grantQueryToJson(
  WorkspaceGrantQuery q, {
  String? keepSelection,
}) => {
  'wireVersion': 1,
  'keyword': q.keyword,
  'filter': q.filter.name,
  'kind': q.kind?.name,
  'lastDays': q.lastDays,
  'offset': q.offset,
  'limit': q.limit,
  'keepSelection': keepSelection,
};
({WorkspaceGrantQuery query, String? keepSelection}) grantQueryFromJson(
  Object? raw,
) => decodeWorkspace(() {
  final q = historyEnvelope(raw, [
    'keyword',
    'filter',
    'kind',
    'lastDays',
    'offset',
    'limit',
    'keepSelection',
  ]);
  return (
    query: WorkspaceGrantQuery(
      keyword: historyText(q['keyword'], max: 2000, empty: true),
      filter: WorkspaceGrantFilter.values.byName(historyText(q['filter'])),
      kind: q['kind'] == null
          ? null
          : WorkspaceApprovalKind.values.byName(historyText(q['kind'])),
      lastDays: _optionalInt(q['lastDays']),
      offset: historyInt(q['offset']),
      limit: historyInt(q['limit'], min: 1, max: 100),
    ),
    keepSelection: _optionalText(q['keepSelection']),
  );
});
Map<String, Object?> _grantSummaryToJson(WorkspaceGrantSummary s) => {
  'id': s.id,
  'title': s.title,
  'kind': s.kind.name,
  'state': s.state.name,
  'agentClaim': s.agentClaim,
  'chatClaim': s.chatClaim,
  'purpose': s.purpose,
  'recordedAt': s.recordedAt.toUtc().toIso8601String(),
  'operationCount': s.operationCount,
  'requestId': s.requestId,
};
WorkspaceGrantSummary _grantSummary(Object? raw) {
  final s = historyWire(raw, [
    'id',
    'title',
    'kind',
    'state',
    'agentClaim',
    'chatClaim',
    'purpose',
    'recordedAt',
    'operationCount',
    'requestId',
  ]);
  return WorkspaceGrantSummary(
    id: historyText(s['id']),
    title: historyText(s['title'], empty: true),
    kind: WorkspaceApprovalKind.values.byName(historyText(s['kind'])),
    state: WorkspaceGrantState.values.byName(historyText(s['state'])),
    agentClaim: historyText(s['agentClaim'], empty: true),
    chatClaim: historyText(s['chatClaim'], empty: true),
    purpose: historyText(s['purpose'], max: 200000, empty: true),
    recordedAt: _date(s['recordedAt']),
    operationCount: historyInt(s['operationCount']),
    requestId: _optionalText(s['requestId']),
  );
}

Map<String, Object?> grantResultsToJson(WorkspaceGrantResults r) => {
  'wireVersion': 1,
  'items': r.items.map(_grantSummaryToJson).toList(),
  'total': r.total,
  'offset': r.offset,
  'selection': r.selection,
  'selectionIndex': r.selectionIndex,
};
WorkspaceGrantResults grantResultsFromJson(Object? raw) => decodeWorkspace(() {
  final r = historyEnvelope(raw, [
    'items',
    'total',
    'offset',
    'selection',
    'selectionIndex',
  ]);
  final items = _list(r['items'], max: 100).map(_grantSummary).toList(),
      total = historyInt(r['total']),
      offset = historyInt(r['offset']);
  final selection = _optionalText(r['selection']),
      index = _optionalInt(r['selectionIndex'], min: 0);
  if (items.length > total ||
      offset > total ||
      (selection == null) != (index == null) ||
      (index != null &&
          (index >= total ||
              (index >= offset &&
                  index < offset + items.length &&
                  items[index - offset].id != selection)))) {
    throw const FormatException('Invalid history selection');
  }
  return WorkspaceGrantResults(
    items: items,
    total: total,
    offset: offset,
    selection: selection,
    selectionIndex: index,
  );
});
Map<String, Object?> grantDetailToJson(WorkspaceGrantDetail d) => {
  'wireVersion': 1,
  'summary': _grantSummaryToJson(d.summary),
  'scopes': [
    for (final s in d.scopes)
      {
        'id': s.id,
        'record': recordRefToJson(s.record),
        'label': s.label,
        'recordVersion': s.recordVersion,
        'kind': s.kind.name,
        'active': s.active,
        'expiresAt': s.expiresAt?.toUtc().toIso8601String(),
        'fileVersion': s.fileVersion,
        'materialVersion': s.materialVersion,
      },
  ],
  'targets': [
    for (final t in d.targets)
      {
        'record': recordRefToJson(t.record),
        'name': t.name,
        'version': t.version,
        'exists': t.exists,
        'snapshotAvailable': t.snapshotAvailable,
      },
  ],
  'events': [
    for (final e in d.events)
      {
        'id': e.id,
        'at': e.at.toUtc().toIso8601String(),
        'description': e.description,
        'result': e.result,
        'proposalId': e.proposalId,
        'fileScopeId': e.fileScopeId,
        'fileVersion': e.fileVersion,
        'fileRecord': e.fileRecord == null
            ? null
            : recordRefToJson(e.fileRecord!),
      },
  ],
  'reviewToken': d.reviewToken,
  'decidedAt': d.decidedAt?.toUtc().toIso8601String(),
  'fieldExpiresAt': d.fieldExpiresAt?.toUtc().toIso8601String(),
  'credentialExpiresAt': d.credentialExpiresAt?.toUtc().toIso8601String(),
  'credentialSessionBound': d.credentialSessionBound,
  'legacyNotice': d.legacyNotice,
  'scopeNotice': d.scopeNotice,
};
WorkspaceGrantDetail grantDetailFromJson(Object? raw) => decodeWorkspace(() {
  final d = historyEnvelope(raw, [
    'summary',
    'scopes',
    'targets',
    'events',
    'reviewToken',
    'decidedAt',
    'fieldExpiresAt',
    'credentialExpiresAt',
    'credentialSessionBound',
    'legacyNotice',
    'scopeNotice',
  ]);
  return WorkspaceGrantDetail(
    summary: _grantSummary(d['summary']),
    scopes: _list(d['scopes']).map((v) {
      final s = historyWire(v, [
        'id',
        'record',
        'label',
        'recordVersion',
        'kind',
        'active',
        'expiresAt',
        'fileVersion',
        'materialVersion',
      ]);
      return WorkspaceGrantedScope(
        id: historyText(s['id']),
        record: recordRefFromJson(s['record']),
        label: historyText(s['label'], empty: true),
        recordVersion: historyInt(s['recordVersion']),
        kind: WorkspaceApprovalScopeKind.values.byName(historyText(s['kind'])),
        active: _bool(s['active']),
        expiresAt: _optionalDate(s['expiresAt']),
        fileVersion: _optionalInt(s['fileVersion']),
        materialVersion: _optionalInt(s['materialVersion']),
      );
    }),
    targets: _list(d['targets']).map((v) {
      final t = historyWire(v, [
        'record',
        'name',
        'version',
        'exists',
        'snapshotAvailable',
      ]);
      return WorkspaceGrantTarget(
        record: recordRefFromJson(t['record']),
        name: historyText(t['name'], empty: true),
        version: historyInt(t['version']),
        exists: _bool(t['exists']),
        snapshotAvailable: _bool(t['snapshotAvailable']),
      );
    }),
    events: _list(d['events']).map((v) {
      final e = historyWire(v, [
        'id',
        'at',
        'description',
        'result',
        'proposalId',
        'fileScopeId',
        'fileVersion',
        'fileRecord',
      ]);
      return WorkspaceGrantEvent(
        historyText(e['id']),
        _date(e['at']),
        historyText(e['description'], max: 200000, empty: true),
        historyText(e['result'], max: 200000, empty: true),
        proposalId: _optionalText(e['proposalId']),
        fileScopeId: _optionalText(e['fileScopeId']),
        fileVersion: _optionalInt(e['fileVersion']),
        fileRecord: e['fileRecord'] == null
            ? null
            : recordRefFromJson(e['fileRecord']),
      );
    }),
    reviewToken: d['reviewToken'] == null ? null : _hash(d['reviewToken']),
    decidedAt: _optionalDate(d['decidedAt']),
    fieldExpiresAt: _optionalDate(d['fieldExpiresAt']),
    credentialExpiresAt: _optionalDate(d['credentialExpiresAt']),
    credentialSessionBound: _bool(d['credentialSessionBound']),
    legacyNotice: _optionalText(d['legacyNotice']),
    scopeNotice: _optionalText(d['scopeNotice']),
  );
});
