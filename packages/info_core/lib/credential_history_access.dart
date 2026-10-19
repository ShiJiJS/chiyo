part of 'info_core.dart';

extension _CredentialHistoryService on InformationService {
  Set<String> _credentialHistoryPruneIds(DateTime cutoff) {
    if (_repository is! CredentialRuntimeRepository) return {};
    final repo = _repository as CredentialRuntimeRepository;
    final executions = <String, List<CredentialExecution>>{};
    for (final execution in repo.credentialExecutions) {
      executions.putIfAbsent(execution.requestId, () => []).add(execution);
    }
    return {
      for (final r in repo.credentialUseRequests)
        if (executions.containsKey(r.id)
            ? executions[r.id]!.every(
                (e) => _credentialHistoryCanPrune(r, e, cutoff),
              )
            : _credentialHistoryCanPrune(r, null, cutoff))
          r.id,
    };
  }

  bool _credentialHistoryCanPrune(
    CredentialUseRequest r,
    CredentialExecution? e,
    DateTime cutoff,
  ) {
    if (_useState(r) == 'pending' || _useGrantState(r) == 'available') {
      return false;
    }
    if (_repository.grantHistory.any(
      (g) => g.requestId == r.id && g.active && _clock().isBefore(g.expiresAt),
    )) {
      return false;
    }
    final times = [
      r.createdAt,
      ?r.decidedAt,
      ?r.revokedAt,
      ?r.attemptedAt,
      ?e?.createdAt,
      ?e?.startedAt,
      ?e?.finishedAt,
    ];
    if (times.any((t) => !t.isBefore(cutoff))) return false;
    if (e == null) return true;
    if ({'preparing', 'running'}.contains(e.state)) return false;
    if (e.materialLease != null && e.cleanupState != 'complete') return false;
    // A legacy unknown record without a registered process group cannot prove
    // its descendants ended. Preserve its identity and any recovery evidence.
    if (e.state == 'unknown' &&
        e.restoredAt == null &&
        (e.jobName == null ||
            CredentialProcessJob.isActive(e.jobName!) != false)) {
      return false;
    }
    return {
      'exited',
      'prepare_failed',
      'start_failed',
      'unknown',
    }.contains(e.state);
  }

  Future<void> _pruneCredentialUseHistory(DateTime cutoff) async {
    if (_repository is! CredentialRuntimeRepository) return;
    final repo = _runtimeRepository;
    final ids = _credentialHistoryPruneIds(cutoff);
    if (ids.isEmpty) return;
    final executionIds = {
      for (final e in repo.credentialExecutions)
        if (ids.contains(e.requestId)) e.id,
    };
    try {
      await repo.commitCredentialRuntime(
        repo.credentialUseRequests.where((r) => !ids.contains(r.id)).toList(),
        repo.credentialExecutions
            .where((e) => !executionIds.contains(e.id))
            .toList(),
      );
    } on Object {
      throw const CredentialUseFailure('audit_unavailable');
    }
    for (final id in ids) {
      _credentialUseSessions.remove(id);
    }
    for (final id in executionIds) {
      _executionCapabilities.remove(id);
    }
  }
}

extension CredentialHistoryOwnerAccess on OwnerAccess {
  Future<void> pruneCredentialUseHistory() => _serialize(
    () => _service._pruneCredentialUseHistory(
      _service._clock().subtract(Duration(days: auditRetentionDays)),
    ),
  );
}
