part of 'sample_workspace_source.dart';

extension _SampleRetention on SampleWorkspaceSource {
  SampleRetentionScope _retentionScope(DateTime cutoff) {
    final a = _approvals, ids = <String>{}, observation = <Object?>[];
    if (_scenario == SampleWorkspaceScenario.empty) {
      return SampleRetentionScope(
        ids: [],
        digest: a.hash([_epoch, 'empty']),
        requests: 0,
        grants: 0,
        operations: 0,
        preserved: 0,
      );
    }
    var requests = 0, grants = 0, operations = 0, preserved = 0;
    for (final r in a._all()) {
      final f = a._facts[r.id], state = a._state(r);
      final executions = a._executions[r.id]?.values.toList() ?? [];
      final events = _proposals.organizationEvents(r.id);
      final times = [
        r.at,
        r.requestExpiresAt,
        ?f?.at,
        ?f?.fieldEnd,
        ?f?.credentialEnd,
        ...executions.map((e) => e.createdAt),
        ...executions.map((e) => e.observedAt).whereType<DateTime>(),
        ...events.map((e) => e.at),
      ];
      final protected =
          !{
            WorkspaceApprovalState.denied,
            WorkspaceApprovalState.revoked,
            WorkspaceApprovalState.expired,
            WorkspaceApprovalState.sessionEnded,
            WorkspaceApprovalState.completed,
          }.contains(state) ||
          executions.any(
            (e) =>
                !e.valid ||
                e.state == WorkspaceExecutionState.preparing ||
                e.state == WorkspaceExecutionState.running ||
                e.processStarted && !e.processEnded ||
                !{
                  WorkspaceExecutionCleanup.notNeeded,
                  WorkspaceExecutionCleanup.complete,
                }.contains(e.cleanup) ||
                e.state == WorkspaceExecutionState.unknown && !e.processEnded,
          ) ||
          r.kind == WorkspaceApprovalKind.organization &&
              _proposals._organizationUnobserved.values.any(
                (x) => x.requestId == r.id,
              );
      observation.add([
        r.id,
        a._stamp(r),
        times.map((t) => t.toIso8601String()).toList(),
        executions.map((e) => e.observationDigest).toList(),
        protected,
      ]);
      if (protected) preserved++;
      if (protected || !times.every((t) => t.isBefore(cutoff))) continue;
      ids.add('request:${r.id}');
      requests++;
      if (f != null && f.action != WorkspaceApprovalAction.deny) grants++;
      operations += executions.length + events.length;
    }
    for (final e in _credentials.retainedHistory.entries) {
      for (final h in e.value) {
        final id = 'legacy:${e.key.key}:${h.grantId}';
        final times = [h.expiresAt, ...h.operations.map((o) => o.at)];
        // The legacy projection has no live process or lease metadata. Only
        // fixture records explicitly known ended are eligible, never unknown.
        final protected = !{'已到期', '已撤销', '会话已结束'}.contains(h.state);
        observation.add([
          id,
          h.state,
          times.map((t) => t.toIso8601String()).toList(),
          h.operations.map((o) => [o.id, o.result]).toList(),
        ]);
        if (protected) preserved++;
        if (protected || !times.every((t) => t.isBefore(cutoff))) continue;
        ids.add(id);
        grants++;
        operations += h.operations.length;
      }
    }
    return SampleRetentionScope(
      ids: ids,
      digest: a.hash([_epoch, observation, ids.toList()..sort()]),
      requests: requests,
      grants: grants,
      operations: operations,
      preserved: preserved,
    );
  }

  void _pruneRetention(Set<String> ids) {
    final a = _approvals;
    for (final r in a._all()) {
      if (!ids.contains('request:${r.id}')) continue;
      a._pruned.add(r.id);
      a._facts.remove(r.id);
      a._executions.remove(r.id);
      a._inputs.remove(r.id);
      a._dynamic.remove(r.id);
      a._organizationFinished.remove(r.id);
    }
    _credentials.pruneRetainedHistory(ids);
  }
}
