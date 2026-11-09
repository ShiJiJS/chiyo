import 'workspace_proposals.dart';
import 'workspace_history.dart';
import 'workspace_transport.dart';

Map<String, Object?> proposalQueryToJson(
  WorkspaceProposalQuery q, {
  String? keepSelection,
}) => {
  'keyword': q.keyword,
  'filter': q.filter.name,
  'kind': q.kind?.name,
  'offset': q.offset,
  'limit': q.limit,
  'keepSelection': keepSelection,
};
WorkspaceProposalQuery proposalQueryFromJson(Map<String, dynamic> q) =>
    decodeWorkspace(() {
      if (q.keys.any(
            (k) => !const {
              'keyword',
              'filter',
              'kind',
              'offset',
              'limit',
              'keepSelection',
            }.contains(k),
          ) ||
          q['keepSelection'] != null && q['keepSelection'] is! String) {
        throw const FormatException();
      }
      return WorkspaceProposalQuery(
        keyword: q['keyword'] as String,
        filter: WorkspaceProposalFilter.values.byName(q['filter'] as String),
        kind: q['kind'] == null
            ? null
            : WorkspaceProposalKind.values.byName(q['kind'] as String),
        offset: q['offset'] as int,
        limit: q['limit'] as int,
      );
    });

Map<String, Object?> proposalSummaryToJson(WorkspaceProposalSummary s) => {
  'id': s.id,
  'title': s.title,
  'kind': s.kind.name,
  'status': s.status.name,
  'pending': s.pending,
  'version': s.version,
  'at': s.at.toIso8601String(),
  'agentClaim': s.agentClaim,
  'chatClaim': s.chatClaim,
  'purpose': s.purpose,
  'itemCount': s.itemCount,
  'wholeDeletion': s.wholeDeletion,
  'organizationOutcome': s.organizationOutcome?.name,
};
WorkspaceProposalSummary proposalSummaryFromJson(Object? value) =>
    decodeWorkspace(() {
      final s = workspaceObject(value);
      return WorkspaceProposalSummary(
        id: s['id'] as String,
        title: s['title'] as String,
        kind: WorkspaceProposalKind.values.byName(s['kind'] as String),
        status: WorkspaceProposalStatus.values.byName(s['status'] as String),
        pending: s['pending'] as bool,
        version: s['version'] as int,
        at: DateTime.parse(s['at'] as String),
        agentClaim: s['agentClaim'] as String,
        chatClaim: s['chatClaim'] as String,
        purpose: s['purpose'] as String,
        itemCount: s['itemCount'] as int,
        wholeDeletion: s['wholeDeletion'] as bool,
        organizationOutcome: s['organizationOutcome'] == null
            ? null
            : WorkspaceOrganizationOutcome.values.byName(
                s['organizationOutcome'] as String,
              ),
      );
    });
Map<String, Object?> proposalResultsToJson(WorkspaceProposalResults r) => {
  'wireVersion': 1,
  'items': r.items.map(proposalSummaryToJson).toList(),
  'total': r.total,
  'pending': r.pending,
  'offset': r.offset,
  'selection': r.selection,
  'selectionIndex': r.selectionIndex,
};
WorkspaceProposalResults proposalResultsFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      if (r['wireVersion'] != 1) throw const FormatException();
      return WorkspaceProposalResults(
        items: (r['items'] as List).map(proposalSummaryFromJson),
        total: r['total'] as int,
        pending: r['pending'] as int,
        offset: r['offset'] as int,
        selection: r['selection'] as String?,
        selectionIndex: r['selectionIndex'] as int?,
      );
    });

Map<String, Object?> proposalItemToJson(WorkspaceProposalItem i) => {
  'id': i.id,
  'proposed': workspaceDetailToJson(i.proposed),
  'before': i.before == null ? null : workspaceDetailToJson(i.before!),
  'beforeState': i.beforeState.name,
  'admissionNote': i.admissionNote,
  'originalProposalVersion': i.originalProposalVersion,
  'credential': i.credential == null
      ? null
      : {
          'source': i.credential!.source,
          'contextExposed': i.credential!.contextExposed,
          'ready': i.credential!.ready,
          'fileName': i.credential!.fileName,
          'account': i.credential!.account,
          'byteLength': i.credential!.byteLength,
        },
  'attachments': [
    for (final a in i.attachments)
      {
        'key': a.key,
        'name': a.name,
        'description': a.description,
        'currentVersion': a.currentVersion,
        'templateField': a.templateField,
        'existingName': a.existingName,
        'previous': a.previous?.toJson(),
        'versions': a.versions.map((v) => v.toJson()).toList(),
      },
  ],
  'changes': [
    for (final c in i.changes)
      {
        'intent': c.intent.name,
        'key': c.key,
        'label': c.label,
        'fieldId': c.fieldId,
        'entryId': c.entryId,
        'leaf': c.leaf,
        'before': c.before,
        'after': c.after,
        'beforeAvailable': c.beforeAvailable,
        'definition': c.definition,
      },
  ],
};
WorkspaceProposalOriginal _original(Object? value) {
  final o = workspaceObject(value);
  return WorkspaceProposalOriginal(
    filename: o['filename'] as String,
    mediaType: o['mediaType'] as String,
    byteLength: o['byteLength'] as int,
    label: o['label'] as String,
    sourceNote: o['sourceNote'] as String,
  );
}

WorkspaceProposalItem proposalItemFromJson(Object? value) => decodeWorkspace(
  () {
    final i = workspaceObject(value);
    final credential = i['credential'] == null
        ? null
        : workspaceObject(i['credential']);
    if (credential != null &&
        credential.keys.any(
          (k) => !const {
            'source',
            'contextExposed',
            'ready',
            'fileName',
            'account',
            'byteLength',
          }.contains(k),
        )) {
      throw const FormatException();
    }
    return WorkspaceProposalItem(
      id: i['id'] as String,
      proposed: workspaceDetailFromJson(i['proposed']),
      before: i['before'] == null ? null : workspaceDetailFromJson(i['before']),
      beforeState: WorkspaceProposalBeforeState.values.byName(
        i['beforeState'] as String,
      ),
      admissionNote: i['admissionNote'] as String,
      originalProposalVersion: i['originalProposalVersion'] as int?,
      credential: credential == null
          ? null
          : WorkspaceProposalCredential(
              source: credential['source'] as String,
              contextExposed: credential['contextExposed'] as bool,
              ready: credential['ready'] as bool,
              fileName: credential['fileName'] as String?,
              account: credential['account'] as String,
              byteLength: credential['byteLength'] as int?,
            ),
      attachments: [
        for (final a in i['attachments'] as List)
          WorkspaceProposalAttachment(
            key: a['key'] as String,
            name: a['name'] as String,
            description: a['description'] as String,
            currentVersion: a['currentVersion'] as int?,
            templateField: a['templateField'] as String?,
            existingName: a['existingName'] as String,
            previous: a['previous'] == null ? null : _original(a['previous']),
            versions: (a['versions'] as List).map(_original),
          ),
      ],
      changes: [
        for (final c in i['changes'] as List)
          WorkspaceProposalFieldChange(
            intent: WorkspaceProposalFieldIntent.values.byName(
              c['intent'] as String,
            ),
            key: c['key'] as String,
            label: c['label'] as String,
            fieldId: c['fieldId'] as String?,
            entryId: c['entryId'] as String?,
            leaf: c['leaf'] as String?,
            before: c['before'] as String?,
            after: c['after'] as String?,
            beforeAvailable: c['beforeAvailable'] as bool,
            definition: c['definition'] == null
                ? null
                : workspaceObject(c['definition']),
          ),
      ],
    );
  },
);

Map<String, Object?> _organization(WorkspaceOrganizationReport r) => {
  ...r.toJson(),
  'members': [
    for (final m in r.members)
      {...m.toJson(), 'record': recordRefToJson(m.record), 'exists': m.exists},
  ],
};
WorkspaceOrganizationLocation _location(Object? value) {
  final l = workspaceObject(value);
  return WorkspaceOrganizationLocation(
    directoryId: l['directoryId'] as String?,
    directoryName: l['directoryName'] as String,
    tags: (l['tags'] as List).map(workspaceTagFromJson),
  );
}

WorkspaceOrganizationReport _readOrganization(Object? value) {
  final r = workspaceObject(value);
  DateTime? date(String key) =>
      r[key] == null ? null : DateTime.parse(r[key] as String);
  return WorkspaceOrganizationReport(
    outcome: WorkspaceOrganizationOutcome.values.byName(r['outcome'] as String),
    at: DateTime.parse(r['at'] as String),
    legacyReview: r['legacyReview'] as bool,
    requestId: r['requestId'] as String?,
    historyId: r['historyId'] as String?,
    operationId: r['operationId'] as String?,
    reason: r['reason'] as String?,
    approvedAt: date('approvedAt'),
    expiresAt: date('expiresAt'),
    members: [
      for (final m in r['members'] as List)
        WorkspaceOrganizationMember(
          record: recordRefFromJson(m['record']),
          name: m['name'] as String,
          baseVersion: m['baseVersion'] as int,
          resultVersion: m['resultVersion'] as int?,
          exists: m['exists'] as bool,
          before: _location(m['before']),
          after: _location(m['after']),
        ),
    ],
  );
}

Map<String, Object?> proposalDetailToJson(WorkspaceProposalDetail d) => {
  'wireVersion': 1,
  'summary': proposalSummaryToJson(d.summary),
  'reviewToken': d.reviewToken,
  'items': d.items.map(proposalItemToJson).toList(),
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
  'notice': d.notice,
  'currentAvailable': d.currentAvailable,
  'currentTargetRef': d.currentTargetRef == null
      ? null
      : recordRefToJson(d.currentTargetRef!),
  'organization': d.organization == null
      ? null
      : _organization(d.organization!),
  'directoryFingerprint': d.directoryFingerprint,
};
WorkspaceProposalDetail proposalDetailFromJson(Object? value) =>
    decodeWorkspace(() {
      final d = workspaceObject(value);
      if (d['wireVersion'] != 1) throw const FormatException();
      final result = WorkspaceProposalDetail(
        summary: proposalSummaryFromJson(d['summary']),
        reviewToken: d['reviewToken'] as String,
        items: (d['items'] as List).map(proposalItemFromJson),
        targets: [
          for (final t in d['targets'] as List)
            WorkspaceProposalTarget(
              record: recordRefFromJson(t['record']),
              name: t['name'] as String,
              version: t['version'] as int,
              exists: t['exists'] as bool,
              snapshotAvailable: t['snapshotAvailable'] as bool,
            ),
        ],
        notice: d['notice'] as String?,
        currentAvailable: d['currentAvailable'] as bool,
        currentTargetRef: d['currentTargetRef'] == null
            ? null
            : recordRefFromJson(d['currentTargetRef']),
        organization: d['organization'] == null
            ? null
            : _readOrganization(d['organization']),
        directoryFingerprint: d['directoryFingerprint'] as String,
      );
      if (result.snapshotDigest != result.reviewToken) {
        throw const FormatException('Changed proposal preview');
      }
      return result;
    });

WorkspaceProposalItemReview proposalReviewFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      if (r.keys.any(
        (k) => !const {
          'id',
          'name',
          'description',
          'directory',
          'suggestedDirectory',
          'tags',
          'values',
          'relations',
        }.contains(k),
      )) {
        throw const FormatException();
      }
      return WorkspaceProposalItemReview(
        itemId: r['id'] as String,
        name: r['name'] as String,
        description: r['description'] as String,
        directoryId: r['directory'] as String?,
        suggestedDirectory: r['suggestedDirectory'] as String? ?? '',
        tagIds: (r['tags'] as List).cast<String>(),
        values: workspaceObject(r['values']),
        relations: workspaceRelationsFromJson(r['relations']),
      );
    });
Map<String, Object?> proposalChangeToJson(WorkspaceProposalChange c) => {
  'operationId': c.operationId,
  'proposalId': c.proposalId,
  'version': c.version,
  'reviewToken': c.reviewToken,
  'action': c.action.name,
  'reviewed': c.reviewed.map((r) => r.toJson()).toList(),
};
WorkspaceProposalChange proposalChangeFromJson(Map<String, dynamic> c) =>
    decodeWorkspace(() {
      if (c.keys.any(
        (k) => !const {
          'operationId',
          'proposalId',
          'version',
          'reviewToken',
          'action',
          'reviewed',
        }.contains(k),
      )) {
        throw const FormatException();
      }
      return WorkspaceProposalChange(
        operationId: c['operationId'] as String,
        proposalId: c['proposalId'] as String,
        version: c['version'] as int,
        reviewToken: c['reviewToken'] as String,
        action: WorkspaceProposalAction.values.byName(c['action'] as String),
        reviewed: (c['reviewed'] as List).map(proposalReviewFromJson),
      );
    });
Map<String, Object?> proposalReceiptToJson(WorkspaceProposalReceipt r) => {
  'operationId': r.operationId,
  'proposalId': r.proposalId,
  'action': r.action.name,
  'reviewToken': r.reviewToken,
  'reviewedVersion': r.reviewedVersion,
  'resultingVersion': r.resultingVersion,
  'commandDigest': r.commandDigest,
  'records': [
    for (final i in r.records)
      {
        'ref': recordRefToJson(i.ref),
        'version': i.version,
        'entryId': i.entryId,
        'notices': i.notices,
      },
  ],
  'awaitingItemIds': r.awaitingItemIds,
};
WorkspaceProposalReceipt proposalReceiptFromJson(Object? value) =>
    decodeWorkspace(() {
      final r = workspaceObject(value);
      return WorkspaceProposalReceipt(
        operationId: r['operationId'] as String,
        proposalId: r['proposalId'] as String,
        action: WorkspaceProposalAction.values.byName(r['action'] as String),
        reviewToken: r['reviewToken'] as String,
        reviewedVersion: r['reviewedVersion'] as int,
        resultingVersion: r['resultingVersion'] as int,
        commandDigest: r['commandDigest'] as String,
        records: [
          for (final i in r['records'] as List)
            WorkspaceRecordReceipt(
              ref: recordRefFromJson(i['ref']),
              version: i['version'] as int,
              entryId: i['entryId'] as String?,
              notices: (i['notices'] as List).cast<String>(),
            ),
        ],
        awaitingItemIds: (r['awaitingItemIds'] as List).cast<String>(),
      );
    });
