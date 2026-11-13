part of 'info_core.dart';

extension _AgentOperationReservations on AgentAccess {
  /// Existing domain records are durable truth. This in-memory reservation
  /// only bridges an asynchronous write: a synchronous field request cannot
  /// reuse its ID while a proposal/credential action is still saving.
  /// It grants no access and is never rebuilt as authority after restart.
  bool _reserveAgentOperation(
    String session,
    String id,
    String kind,
    String digest,
  ) {
    _service._requireSession(session);
    for (final fact in _ownOperationRecords(session)) {
      if (fact['id'] != id) continue;
      final recordedKind =
          {'request-submit', 'proposal-submit'}.contains(fact['kind'])
          ? '${fact['requestKind']}-submit'
          : fact['kind'];
      if (recordedKind != kind) return false;
    }
    final binding = _service._sessionBindings[session]!;
    final records = _service._agentOperationReservations.putIfAbsent(
      binding,
      () => {},
    );
    final prior = records[id];
    if (prior != null) return prior.kind == kind && prior.digest == digest;
    records[id] = (kind: kind, digest: digest);
    return true;
  }
}
