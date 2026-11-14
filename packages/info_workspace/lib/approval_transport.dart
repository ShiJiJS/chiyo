import 'workspace_approvals.dart';
import 'workspace_records.dart';
import 'workspace_files.dart';
import 'credential_use_transport.dart';

/// Versioned owner metadata transport. These projections contain no field
/// values, session secrets, grant tokens or credential material.
Map<String, Object?> approvalQueryToJson(
  WorkspaceApprovalQuery q, {
  String? keepSelection,
}) => {
  'keyword': q.keyword,
  'filter': q.filter.name,
  'offset': q.offset,
  'limit': q.limit,
  'keepSelection': ?keepSelection,
};

T _parse<T>(T Function() decode) {
  try {
    return decode();
  } on Object {
    throw const FormatException('Invalid approval metadata');
  }
}

WorkspaceApprovalQuery approvalQueryFromJson(Map<String, dynamic> j) =>
    _parse(() {
      if (j.keys.any(
            (k) => !const {
              'keyword',
              'filter',
              'offset',
              'limit',
              'keepSelection',
            }.contains(k),
          ) ||
          j['keepSelection'] != null && j['keepSelection'] is! String) {
        throw const FormatException();
      }
      return WorkspaceApprovalQuery(
        keyword: j['keyword'] as String? ?? '',
        filter: WorkspaceApprovalFilter.values.byName(
          j['filter'] as String? ?? 'pending',
        ),
        offset: j['offset'] as int? ?? 0,
        limit: j['limit'] as int? ?? 20,
      );
    });

Map<String, Object?> approvalSummaryToJson(WorkspaceApprovalSummary r) => {
  'id': r.id,
  'title': r.title,
  'kind': r.kind.name,
  'agentClaim': r.agentClaim,
  'sessionId': r.sessionId,
  'chatClaim': r.chatClaim,
  'purpose': r.purpose,
  'submittedAt': r.submittedAt.toUtc().toIso8601String(),
  'requestExpiresAt': r.requestExpiresAt.toUtc().toIso8601String(),
  'state': r.state.name,
};
WorkspaceApprovalSummary _readSummary(Map<String, dynamic> j) =>
    WorkspaceApprovalSummary(
      id: j['id'] as String,
      title: j['title'] as String,
      kind: WorkspaceApprovalKind.values.byName(j['kind'] as String),
      agentClaim: j['agentClaim'] as String,
      sessionId: j['sessionId'] as String,
      chatClaim: j['chatClaim'] as String,
      purpose: j['purpose'] as String,
      submittedAt: DateTime.parse(j['submittedAt'] as String),
      requestExpiresAt: DateTime.parse(j['requestExpiresAt'] as String),
      state: WorkspaceApprovalState.values.byName(j['state'] as String),
    );
Map<String, Object?> approvalResultsToJson(WorkspaceApprovalResults r) => {
  'items': r.items.map(approvalSummaryToJson).toList(),
  'total': r.total,
  'pending': r.pending,
  'offset': r.offset,
  'selection': r.selection,
  'selectionIndex': r.selectionIndex,
};
WorkspaceApprovalResults approvalResultsFromJson(Map<String, dynamic> j) =>
    _parse(
      () => WorkspaceApprovalResults(
        items: (j['items'] as List).map(
          (v) => _readSummary(Map<String, dynamic>.from(v as Map)),
        ),
        total: j['total'] as int,
        pending: j['pending'] as int,
        offset: j['offset'] as int,
        selection: j['selection'] as String?,
        selectionIndex: j['selectionIndex'] as int?,
      ),
    );

Map<String, Object?> approvalDetailToJson(
  WorkspaceApprovalDetail d, {
  int version = 1,
}) {
  // The original endpoint stays v1 and refuses credential details. Only the
  // explicit v2 endpoint can deliver the complete mixed review to a new App.
  if (!{1, 2, 3, 4, 5, 6}.contains(version)) {
    throw const FormatException('Invalid approval version');
  }
  if (d.sshSession && version < 6 ||
      d.credentialBatch && version < 3 ||
      d.programPlan != null && version < 4) {
    throw const WorkspaceFailure('unsupported', '请更新 App 后核对这份多凭据申请。');
  }
  if (version < 5 &&
      (d.operationsCursor != null ||
          d.operationsTotal >
              d.batchOperations.length + d.programOperations.length)) {
    throw const WorkspaceFailure('unsupported', '请更新 App 后分页查看这些使用记录。');
  }
  if (version == 1 && (d.credential != null || d.executions.isNotEmpty)) {
    throw const WorkspaceFailure('unsupported', '此类申请的联网接入尚未完成。');
  }
  return {
    if (version >= 2) ...{
      'version': version,
      'credential': d.credential == null
          ? null
          : credentialUseRequestToJson(d.credential!),
      'executions': d.executions.map(approvalExecutionToJson).toList(),
    },
    if (version >= 3) ...{
      'credentialBatch': d.credentialBatch,
      'batchOperations': d.batchOperations.map((o) => o.toJson()).toList(),
    },
    if (version >= 4) ...{
      'programPlan': d.programPlan?.toJson(),
      'programOperations': d.programOperations.map((o) => o.toJson()).toList(),
    },
    if (version >= 5) ...{
      'operationTotal': d.operationsTotal,
      'operationsCursor': d.operationsCursor,
    },
    if (version >= 6) ...{
      'sshSession': d.sshSession,
      'batchSupportsSessionValidity': d.batchSupportsSessionValidity,
      'batchSessionBound': d.batchSessionBound,
    },
    'request': approvalSummaryToJson(d.request),
    'reviewToken': d.reviewToken,
    'scopes': [
      for (final s in d.scopes)
        {
          'id': s.id,
          'recordKind': s.record.kind.name,
          'recordId': s.record.id,
          'label': s.label,
          'section': s.section,
          'recordName': s.recordName,
          'kind': s.kind.name,
          'recordVersion': s.recordVersion,
          'fieldKey': s.fieldKey,
          'fieldId': s.fieldId,
          'entryId': s.entryId,
          'requested': s.requested,
          'available': s.available,
          'unavailableReason': s.unavailableReason,
          'fileVersions': [
            for (final f in s.fileVersions)
              {
                'ref': f.ref.toJson(),
                'filename': f.filename,
                'mediaType': f.mediaType,
                'byteLength': f.byteLength,
                'createdAt': f.createdAt.toUtc().toIso8601String(),
                'available': f.available,
              },
          ],
        },
    ],
    'approved': d.approved.toList(),
    'fileVersions': d.fileVersions,
    'decidedAt': d.decidedAt?.toUtc().toIso8601String(),
    'fieldExpiresAt': d.fieldExpiresAt?.toUtc().toIso8601String(),
    'credentialExpiresAt': d.credentialExpiresAt?.toUtc().toIso8601String(),
    'approveUnavailableReason': d.approveUnavailableReason,
    'fileVersionPolicy': d.fileVersionPolicy,
    'decisionUnavailableReason': d.decisionUnavailableReason,
  };
}

WorkspaceApprovalDetail approvalDetailFromJson(
  Map<String, dynamic> j,
) => _parse(() {
  final version = j['version'] ?? 1;
  if (!{1, 2, 3, 4, 5, 6}.contains(version) ||
      version >= 6 &&
          (j['sshSession'] is! bool ||
              j['batchSupportsSessionValidity'] is! bool ||
              j['batchSessionBound'] is! bool) ||
      version < 6 &&
          (j.containsKey('sshSession') ||
              j.containsKey('batchSupportsSessionValidity') ||
              j.containsKey('batchSessionBound')) ||
      version >= 2 && !j.containsKey('credential') ||
      version >= 3 && j['credentialBatch'] is! bool ||
      version >= 3 && j['batchOperations'] is! List ||
      version >= 4 &&
          (!j.containsKey('programPlan') || j['programOperations'] is! List) ||
      version >= 5 &&
          (j['operationTotal'] is! int || !j.containsKey('operationsCursor')) ||
      version < 5 &&
          (j.containsKey('operationTotal') ||
              j.containsKey('operationsCursor')) ||
      version < 4 &&
          (j.containsKey('programPlan') ||
              j.containsKey('programOperations')) ||
      version == 1 &&
          (j.containsKey('credential') || j.containsKey('executions'))) {
    throw const FormatException();
  }
  DateTime? date(String k) =>
      j[k] == null ? null : DateTime.parse(j[k] as String);
  final result = WorkspaceApprovalDetail(
    request: _readSummary(Map<String, dynamic>.from(j['request'] as Map)),
    reviewToken: j['reviewToken'] as String,
    scopes: (j['scopes'] as List).map((raw) {
      final s = Map<String, dynamic>.from(raw as Map);
      return WorkspaceApprovalScope(
        id: s['id'] as String,
        record: WorkspaceRecordRef(
          WorkspaceRecordKind.values.byName(s['recordKind'] as String),
          s['recordId'] as String,
        ),
        label: s['label'] as String,
        section: s['section'] as String,
        recordName: s['recordName'] as String,
        kind: WorkspaceApprovalScopeKind.values.byName(s['kind'] as String),
        recordVersion: s['recordVersion'] as int,
        fieldKey: s['fieldKey'] as String?,
        fieldId: s['fieldId'] as String?,
        entryId: s['entryId'] as String?,
        requested: s['requested'] as bool,
        available: s['available'] as bool,
        unavailableReason: s['unavailableReason'] as String?,
        fileVersions: (s['fileVersions'] as List).map((raw) {
          final f = Map<String, dynamic>.from(raw as Map);
          return WorkspaceFileVersion(
            ref: WorkspaceFileRef.fromJson(f['ref']),
            filename: f['filename'] as String,
            mediaType: f['mediaType'] as String,
            byteLength: f['byteLength'] as int,
            createdAt: DateTime.parse(f['createdAt'] as String),
            available: f['available'] as bool,
          );
        }),
      );
    }),
    approved: (j['approved'] as List).cast<String>(),
    fileVersions: Map<String, int>.from(j['fileVersions'] as Map),
    decidedAt: date('decidedAt'),
    fieldExpiresAt: date('fieldExpiresAt'),
    credentialExpiresAt: date('credentialExpiresAt'),
    approveUnavailableReason: j['approveUnavailableReason'] as String?,
    fileVersionPolicy: j['fileVersionPolicy'] as String?,
    decisionUnavailableReason: j['decisionUnavailableReason'] as String?,
    operationTotal: version >= 5 ? j['operationTotal'] as int : null,
    operationsCursor: version >= 5 ? j['operationsCursor'] as String? : null,
    credentialBatch: version >= 3 && j['credentialBatch'] == true,
    sshSession: version >= 6 && j['sshSession'] == true,
    batchSupportsSessionValidity:
        version >= 6 && j['batchSupportsSessionValidity'] == true,
    batchSessionBound: version >= 6 && j['batchSessionBound'] == true,
    programPlan: version >= 4 && j['programPlan'] != null
        ? WorkspaceCredentialProgramPlan.fromJson(
            Map<String, dynamic>.from(j['programPlan'] as Map),
          )
        : null,
    programOperations: version >= 4
        ? (j['programOperations'] as List).map(
            (value) => WorkspaceCredentialProgramOperation.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
        : const [],
    batchOperations: version >= 3
        ? (j['batchOperations'] as List).map(
            (o) => WorkspaceCredentialBatchOperation.fromJson(
              Map<String, dynamic>.from(o as Map),
            ),
          )
        : const [],
    credential: version >= 2 && j['credential'] != null
        ? credentialUseRequestFromJson(j['credential'])
        : null,
    executions: version >= 2
        ? (j['executions'] as List).map(approvalExecutionFromJson)
        : const [],
  );
  if ((result.sshSession &&
          (!result.credentialBatch || result.programPlan != null)) ||
      (!result.sshSession &&
          (result.batchSupportsSessionValidity || result.batchSessionBound)) ||
      (result.batchSessionBound && !result.batchSupportsSessionValidity) ||
      ({
            WorkspaceApprovalKind.credential,
            WorkspaceApprovalKind.focus,
          }.contains(result.request.kind)) !=
          (result.credential != null || result.credentialBatch) ||
      result.credentialBatch &&
          (result.credential != null ||
              result.executions.isNotEmpty ||
              result.scopes.isEmpty ||
              result.scopes.length > 20 ||
              result.scopes.any(
                (s) => s.kind != WorkspaceApprovalScopeKind.credential,
              )) ||
      result.credential != null && result.credential!.id != result.request.id ||
      result.executions.any(
        (e) =>
            e.requestId != result.request.id ||
            e.credential.id != result.credential?.id,
      ) ||
      result.batchOperations.length > (version >= 5 ? 50 : 1000) ||
      result.batchOperations.map((o) => o.operationId).toSet().length !=
          result.batchOperations.length ||
      result.batchOperations.any(
        (o) =>
            !result.credentialBatch ||
            o.requestId != result.request.id ||
            o.itemIds.any((id) => !result.scopes.any((s) => s.id == id)),
      ) ||
      result.programPlan != null &&
          (!result.credentialBatch ||
              result.batchOperations.isNotEmpty ||
              result.scopes.length != result.programPlan!.bindingCount ||
              result.scopes.any(
                (scope) => !result.programPlan!.matchesScope(
                  scope.id,
                  scope.record.id,
                  scope.recordVersion,
                ),
              )) ||
      result.programPlan == null && result.programOperations.isNotEmpty ||
      result.programOperations.length > (version >= 5 ? 50 : 1000) ||
      result.programOperations.map((o) => o.operationId).toSet().length !=
          result.programOperations.length ||
      result.programOperations.any(
        (operation) =>
            operation.requestId != result.request.id ||
            !result.programPlan!.accepts(operation.plan, operation.itemIds),
      )) {
    throw const FormatException('Incomplete credential approval');
  }
  if (version >= 5) {
    final page = WorkspaceCredentialOperationPage.fromJson({
      'version': 1,
      'requestId': result.request.id,
      'program': result.programPlan != null,
      'total': result.operationsTotal,
      'cursor': null,
      'nextCursor': result.operationsCursor,
      'batches': result.batchOperations.map((o) => o.toJson()).toList(),
      'programs': result.programOperations.map((o) => o.toJson()).toList(),
    });
    if (!result.credentialBatch &&
            (page.total != 0 || page.nextCursor != null) ||
        page.total > page.length && page.nextCursor == null) {
      throw const FormatException('Incomplete operation page');
    }
  }
  return result;
});

Map<String, Object?> approvalChangeToJson(WorkspaceApprovalChange c) => {
  'operationId': c.operationId,
  'requestId': c.requestId,
  'reviewToken': c.reviewToken,
  'action': c.action.name,
  'selected': c.selected,
  'fileVersions': c.fileVersions,
  'fieldMinutes': c.fieldMinutes,
  'credentialMinutes': c.credentialMinutes,
};
WorkspaceApprovalChange approvalChangeFromJson(Map<String, dynamic> j) =>
    _parse(() {
      if (j.length != 8 ||
          j.keys.any(
            (k) => !const {
              'operationId',
              'requestId',
              'reviewToken',
              'action',
              'selected',
              'fileVersions',
              'fieldMinutes',
              'credentialMinutes',
            }.contains(k),
          ) ||
          (j['selected'] as List).length > 200 ||
          (j['fileVersions'] as Map).length > 200) {
        throw const FormatException();
      }
      return WorkspaceApprovalChange(
        operationId: j['operationId'] as String,
        requestId: j['requestId'] as String,
        reviewToken: j['reviewToken'] as String,
        action: WorkspaceApprovalAction.values.byName(j['action'] as String),
        selected: (j['selected'] as List).cast<String>(),
        fileVersions: Map<String, int>.from(j['fileVersions'] as Map),
        fieldMinutes: j['fieldMinutes'] as int,
        credentialMinutes: j['credentialMinutes'] as int?,
      );
    });
Map<String, Object?> approvalReceiptToJson(WorkspaceApprovalReceipt r) => {
  'operationId': r.operationId,
  'requestId': r.requestId,
  'action': r.action.name,
  'reviewToken': r.reviewToken,
  'revision': r.revision,
  'commandDigest': r.commandDigest,
};
WorkspaceApprovalReceipt approvalReceiptFromJson(Map<String, dynamic> j) =>
    _parse(
      () => WorkspaceApprovalReceipt(
        operationId: j['operationId'] as String,
        requestId: j['requestId'] as String,
        action: WorkspaceApprovalAction.values.byName(j['action'] as String),
        reviewToken: j['reviewToken'] as String,
        revision: j['revision'] as int,
        commandDigest: j['commandDigest'] as String,
      ),
    );
