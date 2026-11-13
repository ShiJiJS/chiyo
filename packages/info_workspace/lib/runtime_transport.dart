import 'history_transport.dart'
    show historyEnvelope, historyWire, historyText, historyInt;
import 'credential_use_transport.dart';
import 'server_runtime_observation.dart';
import 'workspace_source.dart';

Map<String, Object?> copyMaintenanceToJson(WorkspaceCopyMaintenance c) => {
  'id': c.id,
  'requestId': c.requestId,
  'itemId': c.record.id,
  'name': c.name,
  'fileVersion': c.fileVersion,
  'expiresAt': c.expiresAt.toUtc().toIso8601String(),
  'state': c.state.name,
  'reason': c.reason,
};
WorkspaceCopyMaintenance copyMaintenanceFromJson(Object? raw) {
  final c = historyWire(raw, [
    'id',
    'requestId',
    'itemId',
    'name',
    'fileVersion',
    'expiresAt',
    'state',
    'reason',
  ]);
  return WorkspaceCopyMaintenance(
    id: historyText(c['id']),
    requestId: historyText(c['requestId']),
    record: WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      historyText(c['itemId']),
    ),
    name: historyText(c['name'], empty: true),
    fileVersion: historyInt(c['fileVersion'], min: 1),
    expiresAt: DateTime.parse(historyText(c['expiresAt'])).toUtc(),
    state: WorkspaceCopyState.values.byName(historyText(c['state'])),
    reason: c['reason'] == null ? null : historyText(c['reason']),
  );
}

Map<String, Object?> serverRuntimeToJson(WorkspaceServerRuntimeObservation s) =>
    {
      'wireVersion': s.programs.isEmpty ? 1 : 2,
      'revision': s.revision,
      'materials': s.materials.map(approvalExecutionToJson).toList(),
      'copies': s.copies.map(copyMaintenanceToJson).toList(),
      'sessions': s.sessions,
      'grants': s.grants,
      'pendingRequests': s.pendingRequests,
      'unconfirmedProcesses': s.unconfirmedProcesses,
      if (s.programs.isNotEmpty)
        'programs': s.programs.map((p) => p.toJson()).toList(),
    };
List<dynamic> _list(Object? raw) {
  if (raw is! List || raw.length > 100000) {
    throw const FormatException('Invalid runtime list');
  }
  return raw;
}

WorkspaceServerRuntimeObservation serverRuntimeFromJson(Object? raw) {
  try {
    final version = raw is Map && raw['wireVersion'] == 2 ? 2 : 1;
    final b = historyWire(raw, [
      'wireVersion',
      'revision',
      'materials',
      'copies',
      'sessions',
      'grants',
      'pendingRequests',
      'unconfirmedProcesses',
      if (version == 2) 'programs',
    ]);
    if (b['wireVersion'] != version) {
      throw const FormatException('Invalid runtime version');
    }
    final revision = historyText(b['revision']);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(revision)) {
      throw const FormatException();
    }
    final materials = _list(
      b['materials'],
    ).map(approvalExecutionFromJson).toList();
    final copies = _list(b['copies']).map(copyMaintenanceFromJson).toList();
    final programs = version == 1
        ? <WorkspaceRuntimeProgram>[]
        : _list(b['programs'])
              .map(
                (p) => WorkspaceRuntimeProgram.fromJson(
                  Map<String, dynamic>.from(p as Map),
                ),
              )
              .toList();
    if (materials
                .map((e) => '${e.requestId}/${e.operationId}')
                .toSet()
                .length !=
            materials.length ||
        copies.map((c) => c.id).toSet().length != copies.length ||
        materials.any((e) => e.fromBackup) ||
        programs
                .map(
                  (p) => '${p.operation.requestId}/${p.operation.operationId}',
                )
                .toSet()
                .length !=
            programs.length ||
        programs.where((p) => p.processUnconfirmed).length >
            historyInt(b['unconfirmedProcesses'])) {
      throw const FormatException();
    }
    return WorkspaceServerRuntimeObservation(
      revision: revision,
      materials: List.unmodifiable(materials),
      copies: List.unmodifiable(copies),
      programs: List.unmodifiable(programs),
      sessions: historyInt(b['sessions']),
      grants: historyInt(b['grants']),
      pendingRequests: historyInt(b['pendingRequests']),
      unconfirmedProcesses: historyInt(b['unconfirmedProcesses']),
    );
  } on Object {
    throw const FormatException('Invalid runtime metadata');
  }
}

Map<String, Object?> quitPreviewToJson(WorkspaceQuitPreview p) => {
  'wireVersion': 1,
  'token': p.token,
  'version': p.version,
  ...p.counts,
};
WorkspaceQuitPreview quitPreviewFromJson(Object? raw) {
  final b = historyEnvelope(raw, [
    'token',
    'version',
    'sessions',
    'grants',
    'pendingRequests',
    'materials',
    'copies',
    'unconfirmedProcesses',
    'ownerCopies',
  ]);
  return WorkspaceQuitPreview(
    token: historyText(b['token']),
    version: historyInt(b['version'], min: 1),
    sessions: historyInt(b['sessions']),
    grants: historyInt(b['grants']),
    pendingRequests: historyInt(b['pendingRequests']),
    materials: historyInt(b['materials']),
    copies: historyInt(b['copies']),
    unconfirmedProcesses: historyInt(b['unconfirmedProcesses']),
    ownerCopies: historyInt(b['ownerCopies']),
  );
}

Map<String, Object?> runtimeChangeToJson(WorkspaceRuntimeChange c) => {
  'wireVersion': 1,
  'operationId': c.operationId,
  'action': c.action.name,
  'expectedVersion': c.expectedVersion,
  'quitToken': c.quitToken,
};
WorkspaceRuntimeChange runtimeChangeFromJson(Object? raw) {
  final b = historyEnvelope(raw, [
    'operationId',
    'action',
    'expectedVersion',
    'quitToken',
  ]);
  return WorkspaceRuntimeChange(
    operationId: historyText(b['operationId'], max: 128),
    action: WorkspaceRuntimeAction.values.byName(historyText(b['action'])),
    expectedVersion: historyInt(b['expectedVersion'], min: 1),
    quitToken: b['quitToken'] == null ? null : historyText(b['quitToken']),
  );
}

Map<String, Object?> runtimeReceiptToJson(WorkspaceRuntimeReceipt r) => {
  'wireVersion': 1,
  'operationId': r.operationId,
  'commandDigest': r.commandDigest,
  'action': r.action.name,
  'expectedVersion': r.expectedVersion,
  'version': r.version,
  'phase': r.phase.name,
  'windowHidden': r.windowHidden,
  'checked': r.checked,
  'released': r.released,
  'retained': r.retained,
  'quitScope': r.quitScope == null ? null : quitPreviewToJson(r.quitScope!),
};
WorkspaceRuntimeReceipt runtimeReceiptFromJson(Object? raw) {
  final b = historyEnvelope(raw, [
    'operationId',
    'commandDigest',
    'action',
    'expectedVersion',
    'version',
    'phase',
    'windowHidden',
    'checked',
    'released',
    'retained',
    'quitScope',
  ]);
  if (b['windowHidden'] is! bool ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(historyText(b['commandDigest']))) {
    throw const FormatException('Invalid runtime result');
  }
  return WorkspaceRuntimeReceipt(
    operationId: historyText(b['operationId'], max: 128),
    commandDigest: b['commandDigest'] as String,
    action: WorkspaceRuntimeAction.values.byName(historyText(b['action'])),
    expectedVersion: historyInt(b['expectedVersion'], min: 1),
    version: historyInt(b['version'], min: 1),
    phase: WorkspaceRuntimePhase.values.byName(historyText(b['phase'])),
    windowHidden: b['windowHidden'] as bool,
    checked: historyInt(b['checked']),
    released: historyInt(b['released']),
    retained: historyInt(b['retained']),
    quitScope: b['quitScope'] == null
        ? null
        : quitPreviewFromJson(b['quitScope']),
  );
}
