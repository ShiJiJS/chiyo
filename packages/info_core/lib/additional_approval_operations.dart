part of 'info_core.dart';

/// Owner decisions for the existing credential and organization protocols.
/// The receipt is committed by their original storage transaction.
abstract interface class AdditionalApprovalRepository {
  Future<InformationApprovalReceipt?> additionalApprovalReceipt(String id);
  Future<int> additionalApprovalRevision(String requestId);
}

final _additionalApprovalKey = Object();

class AdditionalApprovalOperation {
  AdditionalApprovalOperation._(this.owner, this.kind, this.command, this.guard)
    : scope = owner.captureLibraryScope();
  final OwnerAccess owner;
  final String kind;
  final InformationApprovalReceipt command;
  final void Function() guard;
  final OwnerLibraryScope scope;
  bool active = true, entered = false, written = false;
  void validate() {
    if (!scope.isCurrent) throw const AccessFailure('library_changed');
    if (!owner.serviceAvailable) {
      throw const AccessFailure('service_unavailable');
    }
    guard();
  }

  Future<void> before(OwnerAccess caller) async {
    if (!active || entered) return;
    if (!identical(caller, owner)) {
      throw const AccessFailure('invalid_operation');
    }
    entered = true;
    final prior = await owner._additionalApprovals.additionalApprovalReceipt(
      command.operationId,
    );
    if (prior != null) {
      _checkAdditionalReceipt(prior, command);
      throw _AdditionalCommitted(prior);
    }
    validate();
  }

  InformationApprovalReceipt complete(
    String requestId,
    String requestKind,
    int revision,
  ) {
    if (!entered ||
        written ||
        command.requestId != requestId ||
        kind != requestKind) {
      throw const AccessFailure('request_changed');
    }
    validate();
    written = true;
    return InformationApprovalReceipt(
      operationId: command.operationId,
      requestId: requestId,
      action: command.action,
      reviewToken: command.reviewToken,
      commandDigest: command.commandDigest,
      revision: revision,
      recordedAt: command.recordedAt,
      metadata: command.metadata,
    );
  }
}

AdditionalApprovalOperation? get pendingAdditionalApproval {
  final context =
      Zone.current[_additionalApprovalKey] as AdditionalApprovalOperation?;
  return context?.active == true ? context : null;
}

void _checkAdditionalReceipt(
  InformationApprovalReceipt a,
  InformationApprovalReceipt b,
) {
  if (a.requestId != b.requestId ||
      a.action != b.action ||
      a.reviewToken != b.reviewToken ||
      a.commandDigest != b.commandDigest) {
    throw const AccessFailure('operation_conflict');
  }
}

class _AdditionalCommitted implements Exception {
  _AdditionalCommitted(this.receipt);
  final InformationApprovalReceipt receipt;
}

extension OwnerAdditionalApprovals on OwnerAccess {
  AdditionalApprovalRepository get _additionalApprovals =>
      _service._repository is AdditionalApprovalRepository
      ? _service._repository as AdditionalApprovalRepository
      : throw const AccessFailure('unsupported_capability');
  Future<InformationApprovalReceipt?> additionalApprovalReceipt(
    String id,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    // A repository without this commit capability cannot contain one of
    // these receipts. Keep ordinary-only memory adapters usable.
    if (_service._repository is! AdditionalApprovalRepository) return null;
    final receipt = await _additionalApprovals.additionalApprovalReceipt(id);
    _service._uncertainCredentialDecisions.remove(id)?.call(receipt != null);
    return receipt;
  });

  /// Revoke all approved components of one mixed request. The legacy
  /// credential-only revoke API remains separate for its existing callers.
  Future<void> revokeCredentialRequest(String id) => _serialize(() async {
    final operation = pendingAdditionalApproval;
    if (operation == null ||
        operation.kind != 'credential' ||
        operation.command.requestId != id ||
        operation.command.action != InformationApprovalAction.revoke) {
      throw const AccessFailure('invalid_operation');
    }
    final r = _service._useRequest(id), request = _service._requests[id];
    if (r.invalidatedCode == 'grant_revoked' ||
        (!r.credentialApproved && r.approvedFields.isEmpty)) {
      throw const CredentialUseFailure('request_terminal');
    }
    if (request?.informationDecisionPending == true) {
      throw const CredentialUseFailure('audit_unavailable');
    }
    await _service._auditWrites;
    if (_service._auditFailed) {
      throw const CredentialUseFailure('audit_unavailable');
    }
    final now = _service._clock().toUtc();
    final oldHistory = request?.history;
    final nextHistory = oldHistory?.active == true
        ? oldHistory!.finish(GrantEventKind.revoked, now)
        : null;
    final original = _service._repository.requestHistory
        .where((h) => h.id == id)
        .firstOrNull;
    final fieldRequest = nextHistory == null || original == null
        ? null
        : RequestHistory.fromJson({
            ...original.toJson(),
            'state': AccessRequestState.revoked.name,
            'recordedAt': now.toIso8601String(),
          });
    if (nextHistory != null && fieldRequest == null) {
      throw const CredentialUseFailure('audit_unavailable');
    }
    if (request != null) request.informationDecisionPending = true;
    void settle(bool committed) {
      if (request != null) {
        if (committed) {
          request.state = AccessRequestState.revoked;
          if (nextHistory != null) request.history = nextHistory;
        }
        request.informationDecisionPending = false;
        _service._recordDeferredInformationRequest(request);
      }
      if (committed) _service._scheduleInformationDeliveryCleanup();
    }

    try {
      await _service._saveUse(
        request: r.changed({
          'invalidatedCode': 'grant_revoked',
          'revokedAt': _useTimestamp(now),
        }),
        fieldGrant: nextHistory,
        fieldRequest: fieldRequest,
        validate: operation.validate,
      );
      settle(true);
    } on Object {
      // Block reads while commit outcome is unknown. Resolve only by the same
      // durable receipt; a failed query must keep the barrier in place.
      _service._uncertainCredentialDecisions[operation.command.operationId] =
          settle;
      try {
        final receipt = await _additionalApprovals.additionalApprovalReceipt(
          operation.command.operationId,
        );
        _service._uncertainCredentialDecisions
            .remove(operation.command.operationId)
            ?.call(receipt != null);
      } on Object {
        /* Leave the barrier until original receipt can be read. */
      }
      rethrow;
    }
  });
  Future<int> additionalApprovalRevision(String requestId) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        return _additionalApprovals.additionalApprovalRevision(requestId);
      });
  Future<InformationApprovalReceipt> performAdditionalApproval({
    required String operationId,
    required String requestId,
    required String kind,
    required InformationApprovalAction action,
    required String reviewToken,
    required String commandDigest,
    required void Function() validate,
    required Future<void> Function() decide,
    Map<String, Object?> metadata = const {},
  }) {
    final result = _performAdditionalApproval(
      operationId: operationId,
      requestId: requestId,
      kind: kind,
      action: action,
      reviewToken: reviewToken,
      commandDigest: commandDigest,
      validate: validate,
      decide: decide,
      metadata: metadata,
    );
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _service._informationDecisionWrites.add(settled);
    settled.then((_) => _service._informationDecisionWrites.remove(settled));
    return result;
  }

  Future<InformationApprovalReceipt> _performAdditionalApproval({
    required String operationId,
    required String requestId,
    required String kind,
    required InformationApprovalAction action,
    required String reviewToken,
    required String commandDigest,
    required void Function() validate,
    required Future<void> Function() decide,
    Map<String, Object?> metadata = const {},
  }) async {
    if (!serviceAvailable ||
        pendingAdditionalApproval != null ||
        !{'credential', 'organization', 'ssh'}.contains(kind)) {
      throw const AccessFailure('invalid_operation');
    }
    final command = InformationApprovalReceipt(
      operationId: operationId,
      requestId: requestId,
      action: action,
      reviewToken: reviewToken,
      commandDigest: commandDigest,
      revision: 1,
      recordedAt: _service._clock().toUtc(),
      metadata: metadata,
    );
    if (_service._repository is InformationApprovalRepository &&
        await (_service._repository as InformationApprovalRepository)
                .informationApprovalReceipt(operationId) !=
            null) {
      throw const AccessFailure('operation_conflict');
    }
    final prior = await additionalApprovalReceipt(operationId);
    if (prior != null) {
      _checkAdditionalReceipt(prior, command);
      return prior;
    }
    final context = AdditionalApprovalOperation._(
      this,
      kind,
      command,
      validate,
    );
    try {
      await runZoned(decide, zoneValues: {_additionalApprovalKey: context});
    } on _AdditionalCommitted catch (e) {
      return e.receipt;
    } finally {
      context.active = false;
    }
    final result = await additionalApprovalReceipt(operationId);
    if (result == null) throw const AccessFailure('unknown_outcome');
    return result;
  }
}
