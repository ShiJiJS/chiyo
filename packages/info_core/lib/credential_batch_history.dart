part of 'info_core.dart';

/// A whole request and all its operations form one retention unit. The digest
/// fences a preview against both changed operations and newly appended ones.
/// This is metadata only; it neither carries material nor authorizes execution.
final class CredentialBatchHistoryPrune {
  CredentialBatchHistoryPrune({
    required Iterable<CredentialUseBatch> requests,
    required Iterable<CredentialBatchOperation> operations,
    required Iterable<CredentialProgramOperation> programs,
  }) : requestIds = Set.unmodifiable(requests.map((r) => r.id)) {
    if (requestIds.isEmpty || requestIds.length != requests.length) {
      throw const CredentialUseFailure('invalid_reference');
    }
    digest = _digest(requests, operations, programs);
  }

  final Set<String> requestIds;
  late final String digest;

  String _digest(
    Iterable<CredentialUseBatch> requests,
    Iterable<CredentialBatchOperation> operations,
    Iterable<CredentialProgramOperation> programs,
  ) {
    final rows = <String>[
      for (final r in requests)
        if (requestIds.contains(r.id)) jsonEncode(['request', r.toJson()]),
      for (final o in operations)
        if (requestIds.contains(o.requestId)) jsonEncode(['fill', o.toJson()]),
      for (final o in programs)
        if (requestIds.contains(o.requestId))
          jsonEncode(['program', o.toStorageJson()]),
    ]..sort();
    return _useFingerprint(rows);
  }

  void validateAgainst(
    Iterable<CredentialUseBatch> requests,
    Iterable<CredentialBatchOperation> operations,
    Iterable<CredentialProgramOperation> programs,
  ) {
    if (_digest(requests, operations, programs) != digest) {
      throw const CredentialUseFailure('operation_conflict');
    }
  }
}

extension _CredentialBatchHistoryService on InformationService {
  /// A live (including resumable online) chat still needs its original IDs for
  /// idempotency. Keep its source records rather than maintaining another
  /// permanent replay ledger. Ended chats can never recover that authority.
  bool _credentialHistoryBindingCanPrune(String? binding) =>
      binding == null ||
      !_sessionBindings.entries.any(
        (e) => e.value == binding && !_endedSessions.contains(e.key),
      );

  Set<String> _credentialBatchHistoryPruneIds(DateTime cutoff) {
    final Object repo = _repository;
    if (repo is! CredentialBatchRepository) return {};
    final fills = <String, List<CredentialBatchOperation>>{};
    for (final o in repo.credentialBatchOperations) {
      fills.putIfAbsent(o.requestId, () => []).add(o);
    }
    final programs = <String, List<CredentialProgramOperation>>{};
    if (repo is CredentialProgramRepository) {
      for (final o
          in (repo as CredentialProgramRepository)
              .credentialProgramOperations) {
        programs.putIfAbsent(o.requestId, () => []).add(o);
      }
    }
    return {
      for (final r in repo.credentialBatches)
        if ((r.archived ||
                _credentialHistoryBindingCanPrune(r.sessionBinding)) &&
            _batchState(r) != 'pending' &&
            !r.items.any((i) => _batchItemState(r, i) == 'available') &&
            [
              r.createdAt,
              ...r.decisions.map((d) => d.at),
            ].every((t) => t.isBefore(cutoff)) &&
            (fills[r.id] ?? const []).every(
              (o) => _batchFillHistoryCanPrune(r, o, cutoff),
            ) &&
            (programs[r.id] ?? const []).every(
              (o) => _batchProgramHistoryCanPrune(o, cutoff),
            ))
          r.id,
    };
  }

  bool _batchFillHistoryCanPrune(
    CredentialUseBatch request,
    CredentialBatchOperation operation,
    DateTime cutoff,
  ) {
    if ({
      CredentialBatchOperationState.checking,
      CredentialBatchOperationState.dispatched,
    }.contains(operation.state)) {
      return false;
    }
    if (!request.archived &&
        {
          CredentialBatchOperationState.partial,
          CredentialBatchOperationState.unknown,
        }.contains(operation.state) &&
        operation.attentionAcknowledgedAt == null) {
      return false;
    }
    return [
      operation.createdAt,
      ?operation.finishedAt,
      ?operation.attentionAcknowledgedAt,
    ].every((t) => t.isBefore(cutoff));
  }

  bool _batchProgramHistoryCanPrune(
    CredentialProgramOperation operation,
    DateTime cutoff,
  ) {
    final p = operation.progress;
    if ({'preparing', 'running'}.contains(p.state)) {
      return false;
    }
    if (!operation.archived &&
        (!{'not_needed', 'complete'}.contains(p.cleanupState) ||
            (p.processStarted || p.workerPid != null || p.state == 'unknown') &&
                _credentialProgramProofs[operation.id]?.treeEnded != true)) {
      return false;
    }
    return [
      p.createdAt!,
      ?p.startedAt,
      ?p.finishedAt,
    ].every((t) => t.isBefore(cutoff));
  }

  Future<void> _pruneCredentialBatchHistory(
    DateTime cutoff,
  ) => _serializeRuntimeWrite(() async {
    final Object repo = _repository;
    if (repo is! CredentialBatchRepository) return;
    final ids = _credentialBatchHistoryPruneIds(cutoff);
    if (ids.isEmpty) return;
    final plan = CredentialBatchHistoryPrune(
      requests: repo.credentialBatches.where((r) => ids.contains(r.id)),
      operations: repo.credentialBatchOperations,
      programs: repo is CredentialProgramRepository
          ? (repo as CredentialProgramRepository).credentialProgramOperations
          : const [],
    );
    void validate() {
      if (_closed ||
          _backupBusy ||
          !_credentialBatchHistoryPruneIds(cutoff).containsAll(ids)) {
        throw const CredentialUseFailure('operation_conflict');
      }
    }

    await repo.pruneCredentialBatchHistory(plan, validate: validate);
    _batchMaterialProofs.removeWhere(
      (_, p) => !repo.credentialBatchOperations.any(
        (o) =>
            o.operationId == p.operationId &&
            o.sessionBinding == p.sessionBinding,
      ),
    );
    _credentialProgramProofs.removeWhere(
      (id, _) =>
          repo is CredentialProgramRepository &&
          !(repo as CredentialProgramRepository).credentialProgramOperations
              .any((o) => o.id == id),
    );
  });
}
