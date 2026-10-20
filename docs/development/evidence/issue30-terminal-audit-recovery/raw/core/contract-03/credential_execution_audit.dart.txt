part of 'info_core.dart';

extension _CredentialExecutionAudit on InformationService {
  // Deferred audit recovery also writes request/execution lists. Serialize all
  // runtime commits and build their lists inside this lock, so a repair cannot
  // overwrite an unrelated command, fill or retention write. This is separate
  // from the owner lock: backup holds that lock while draining audit writes.
  Future<T> _serializeRuntimeWrite<T>(Future<T> Function() action) {
    final result = _runtimeWrites.then((_) => action());
    _runtimeWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _requireSettledExecutionReceipt(String id) {
    if (_pendingExecutionReceipts.containsKey(id)) {
      throw const CredentialUseFailure('audit_unavailable');
    }
  }

  CredentialExecution _executionForDisplay(CredentialExecution execution) =>
      !_pendingExecutionReceipts.containsKey(execution.id)
      ? execution
      : execution.changed({
          'executionState': 'unknown',
          'finishedAt': null,
          'exitCode': null,
          'errorCode': 'audit_unavailable',
        });

  void _queueExecutionReceipt(String id, Map<String, Object?> facts) {
    if (_pendingExecutionReceipts.containsKey(id)) return;
    final receipt = Map<String, Object?>.unmodifiable(facts);
    final repository = _repository as CredentialRuntimeRepository;
    _pendingExecutionReceipts[id] = receipt;
    _enqueueAudit(
      () => _serializeRuntimeWrite(() async {
        if (!identical(_pendingExecutionReceipts[id], receipt)) return;
        final current = repository.credentialExecutions
            .where((e) => e.id == id)
            .firstOrNull;
        if (current == null) {
          throw const CredentialUseFailure('audit_unavailable');
        }
        // Only already authenticated, validated terminal metadata is retried.
        // Never retain material or replay a grant/launch snapshot. Rebase onto
        // the latest row, preserving its private lease and cleanup facts.
        await repository
            .commitCredentialRuntime(repository.credentialUseRequests, [
              for (final e in repository.credentialExecutions)
                if (e.id == id) e.changed(receipt) else e,
            ]);
        _pendingExecutionReceipts.remove(id);
      }),
    );
  }
}
