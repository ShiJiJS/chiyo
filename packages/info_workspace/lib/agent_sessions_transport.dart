import 'agent_sessions.dart';
import 'approval_transport.dart';
import 'history_transport.dart'
    show historyEnvelope, historyWire, historyText, historyInt;
import 'workspace_agents.dart';

Map<String, Object?> agentSessionsToJson(WorkspaceAgentSessions s) => {
  'wireVersion': 1,
  'revision': s.revision,
  'serviceAvailable': s.serviceAvailable,
  'sessions': s.sessions.map((s) => s.json).toList(),
  'requests': s.requests.map(approvalSummaryToJson).toList(),
};
WorkspaceAgentSessions agentSessionsFromJson(Object? raw) {
  try {
    final b = historyEnvelope(raw, [
      'revision',
      'serviceAvailable',
      'sessions',
      'requests',
    ]);
    final available = b['serviceAvailable'];
    if (available is! bool ||
        b['sessions'] is! List ||
        b['requests'] is! List ||
        (b['sessions'] as List).length > 100000 ||
        (b['requests'] as List).length > 100000) {
      throw const FormatException();
    }
    final sessions = <WorkspaceAgentSession>[];
    for (final raw in b['sessions'] as List) {
      final s = historyWire(raw, [
        'state',
        'id',
        'label',
        'requests',
        'pending',
        'grants',
      ]);
      sessions.add(
        WorkspaceAgentSession(
          state: WorkspaceAgentSessionState.values.byName(
            historyText(s['state']),
          ),
          id: historyText(s['id']),
          label: s['label'] == null
              ? null
              : historyText(s['label'], empty: true),
          totalRequests: historyInt(s['requests']),
          pendingRequests: historyInt(s['pending']),
          activeGrants: historyInt(s['grants']),
        ),
      );
    }
    final requestJson = <Map<String, dynamic>>[];
    for (final raw in b['requests'] as List) {
      final r = historyWire(raw, [
        'id',
        'title',
        'kind',
        'agentClaim',
        'sessionId',
        'chatClaim',
        'purpose',
        'submittedAt',
        'requestExpiresAt',
        'state',
      ]);
      for (final key in r.keys) {
        historyText(
          r[key],
          max: 200000,
          empty: const [
            'title',
            'agentClaim',
            'chatClaim',
            'purpose',
          ].contains(key),
        );
      }
      requestJson.add(r);
    }
    // Reuse the original approval metadata decoder, after strict field checks.
    final requests = approvalResultsFromJson({
      'items': requestJson,
      'total': requestJson.length,
      'pending': 0,
      'offset': 0,
      'selection': null,
      'selectionIndex': null,
    }).items;
    final result = WorkspaceAgentSessions(
      revision: historyText(b['revision']),
      serviceAvailable: available,
      sessions: sessions,
      requests: requests,
    );
    if (!result.valid) throw const FormatException();
    return result;
  } on Object {
    throw const FormatException('Invalid agent session metadata');
  }
}
