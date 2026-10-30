part of 'info_core.dart';

/// Trusted owner command. The caller binds commandDigest to its complete UI
/// intent (including reviewToken); it is never accepted through Agent transport.
final class InformationApprovalCommand {
  InformationApprovalCommand({
    required this.operationId,
    required this.requestId,
    required this.action,
    required this.reviewToken,
    required this.commandDigest,
    Iterable<FieldRef> fields = const [],
    Map<String, int> itemVersions = const {},
    this.lifetime = const Duration(minutes: 30),
  }) : fields = List.unmodifiable(fields),
       itemVersions = Map.unmodifiable(itemVersions) {
    InformationApprovalReceipt(
      operationId: operationId,
      requestId: requestId,
      action: action,
      reviewToken: reviewToken,
      commandDigest: commandDigest,
      revision: 1,
      recordedAt: DateTime.utc(2000),
    );
    if (this.fields.length > 200 ||
        this.fields.toSet().length != this.fields.length ||
        this.itemVersions.length > 200 ||
        this.itemVersions.values.any((v) => v < 1) ||
        (action == InformationApprovalAction.approve
            ? this.fields.isEmpty ||
                  lifetime < const Duration(minutes: 1) ||
                  lifetime > const Duration(days: 7) ||
                  this.fields.map((f) => f.itemId).toSet().length !=
                      this.itemVersions.length ||
                  this.fields.any(
                    (f) => !this.itemVersions.containsKey(f.itemId),
                  )
            : this.fields.isNotEmpty || this.itemVersions.isNotEmpty)) {
      throw const FormatException('Invalid information approval command');
    }
  }
  final String operationId, requestId, reviewToken, commandDigest;
  final InformationApprovalAction action;
  final List<FieldRef> fields;
  final Map<String, int> itemVersions;
  final Duration lifetime;

  bool matches(InformationApprovalReceipt receipt) =>
      operationId == receipt.operationId &&
      requestId == receipt.requestId &&
      action == receipt.action &&
      reviewToken == receipt.reviewToken &&
      commandDigest == receipt.commandDigest;
}

/// Captures non-secret audit identity before close clears the session maps.
/// A deferred decision never publishes its proposed bearer until commit returns.
final class _InformationDecision {
  _InformationDecision(this.service, this.request, this.change)
    : generation = service._libraryGeneration;
  final InformationService service;
  final _Request request;
  final InformationApprovalCommit change;
  final int generation;

  void validate() {
    if (generation != service._libraryGeneration) {
      throw const AccessFailure('library_changed');
    }
    service._expire(request);
    if (!service._sessionActive(request.session) ||
        !identical(service._requests[request.id], request) ||
        request.state !=
            (change.receipt.action == InformationApprovalAction.revoke
                ? AccessRequestState.approved
                : AccessRequestState.pending)) {
      throw const AccessFailure('request_changed');
    }
    for (final entry in change.itemVersions.entries) {
      if (service._repository.items
              .where((i) => i.id == entry.key)
              .firstOrNull
              ?.version !=
          entry.value) {
        throw const AccessFailure('scope_changed');
      }
    }
    if (change.receipt.action == InformationApprovalAction.approve &&
        !service._clock().isBefore(change.grant!.expiresAt)) {
      throw const AccessFailure('request_changed');
    }
  }

  void settle({required bool committed, required bool uncertain}) {
    // A successful library restore has already discarded every live capability.
    if (generation != service._libraryGeneration) return;
    var valid = false;
    try {
      validate();
      valid = true;
    } on AccessFailure {
      /* terminal state wins */
    }
    if (committed) {
      switch (change.receipt.action) {
        case InformationApprovalAction.approve:
          request.approvedAt = change.grant!.approvedAt;
          request.history = change.grant;
          if (valid && !uncertain) {
            final grant = ClaimedGrant(
              service._secret(),
              change.grant!.fields
                  .map((f) => FieldRef(f.itemId, f.fieldId))
                  .toList(),
              change.grant!.expiresAt,
            );
            request.grant = grant;
            request.state = AccessRequestState.approved;
            service._grants[grant.token] = request;
          } else {
            final kind = service._closed
                ? GrantEventKind.applicationClosed
                : request.decisionSessionEnded ||
                      service._endedSessions.contains(request.session)
                ? GrantEventKind.ended
                : !service._clock().isBefore(change.grant!.expiresAt)
                ? GrantEventKind.expired
                : GrantEventKind.revoked;
            request.state = kind == GrantEventKind.expired
                ? AccessRequestState.expired
                : AccessRequestState.revoked;
            request.history = change.grant!.finish(
              kind,
              kind == GrantEventKind.expired
                  ? change.grant!.expiresAt
                  : service._clock(),
            );
          }
        case InformationApprovalAction.deny:
          if (valid) request.state = AccessRequestState.denied;
        case InformationApprovalAction.revoke:
          // Preserve a concurrent end/expiry event, which was latched in memory.
          if (request.history?.active ?? true) request.history = change.grant;
          if (valid) request.state = AccessRequestState.revoked;
      }
    }
    request.informationDecisionPending = false;
    request.deferredDecisionRequest = null;
    // Normal success already persisted these exact facts atomically. Only a
    // competing terminal event or uncertain response needs a follow-up audit.
    if ((committed || request.state != AccessRequestState.pending) &&
        (!committed || !valid || uncertain)) {
      final history = request.history;
      final original = change.request;
      final outcome = RequestHistory(
        id: original.id,
        sessionId: original.sessionId,
        chatLabel: original.chatLabel,
        purpose: original.purpose,
        createdAt: original.createdAt,
        requestExpiresAt: original.requestExpiresAt,
        recordedAt: service._clock(),
        state: request.state,
        fields: original.fields,
        grantId: history?.id,
        sessionEnded:
            request.decisionSessionEnded ||
            service._endedSessions.contains(request.session),
        applicationClosed: request.decisionApplicationClosed || service._closed,
      );
      // Terminal events were latched while this request's audit writes were
      // deferred. Append their final facts only after the decision transaction.
      service._enqueueAudit(() async {
        if (history != null) {
          await service._repository.saveGrantHistory(history);
        }
        await service._repository.saveRequestHistory(outcome);
      });
    }
    service._scheduleInformationDeliveryCleanup();
  }
}

extension _InformationDecisionService on InformationService {
  Future<void> _drainInformationDecisions() async {
    while (_informationDecisionWrites.isNotEmpty) {
      await Future.wait(_informationDecisionWrites.toList());
    }
    for (final entry in _uncertainInformationDecisions.entries.toList()) {
      await owner._resolveInformationDecision(entry.key, entry.value);
    }
    await owner.retryAuditStorage();
  }
}

extension OwnerInformationApprovals on OwnerAccess {
  InformationApprovalRepository get _approvalOperations {
    if (_service._repository
        case final InformationApprovalRepository repository) {
      return repository;
    }
    throw const AccessFailure('unsupported_capability');
  }

  Future<InformationApprovalReceipt?> _resolveInformationDecision(
    String id,
    _InformationDecision decision,
  ) async {
    final receipt = await _approvalOperations.informationApprovalReceipt(id);
    if (receipt != null &&
        jsonEncode(receipt.toJson()) !=
            jsonEncode(decision.change.receipt.toJson())) {
      throw const AccessFailure('operation_conflict');
    }
    decision.settle(committed: receipt != null, uncertain: true);
    _service._uncertainInformationDecisions.remove(id);
    return receipt;
  }

  /// Queries an original result, including after navigation or restart. Resolving
  /// an ambiguous commit may finish its audit, but never activates a capability.
  Future<InformationApprovalReceipt?> informationApprovalReceipt(String id) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id)) {
          throw const AccessFailure('invalid_operation');
        }
        final pending = _service._uncertainInformationDecisions[id];
        final receipt = pending == null
            ? await _approvalOperations.informationApprovalReceipt(id)
            : await _resolveInformationDecision(id, pending);
        await _service._auditWrites;
        if (_service._auditFailed) {
          throw const AccessFailure('audit_unavailable');
        }
        return receipt;
      });

  Future<InformationApprovalReceipt> decideInformationRequest(
    InformationApprovalCommand command,
  ) {
    final result = _serialize(() => _decideInformationRequest(command));
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _service._informationDecisionWrites.add(settled);
    settled.then((_) => _service._informationDecisionWrites.remove(settled));
    return result;
  }

  Future<InformationApprovalReceipt> _decideInformationRequest(
    InformationApprovalCommand command,
  ) async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final repository = _approvalOperations;
    final pending =
        _service._uncertainInformationDecisions[command.operationId];
    final old = pending == null
        ? await repository.informationApprovalReceipt(command.operationId)
        : await _resolveInformationDecision(command.operationId, pending);
    if (old != null) {
      if (!command.matches(old)) {
        throw const AccessFailure('operation_conflict');
      }
      return old; // Never replay a decision or revive a finished capability.
    }
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final request = _service._requests[command.requestId];
    if (request == null ||
        _service._credentialUseSessions.containsKey(request.id)) {
      throw const AccessFailure('invalid_request');
    }
    if (request.informationDecisionPending) {
      throw const AccessFailure('decision_unknown');
    }
    _service._expire(request);
    final expected = command.action == InformationApprovalAction.revoke
        ? AccessRequestState.approved
        : AccessRequestState.pending;
    if (!_service._sessionActive(request.session) ||
        request.state != expected) {
      throw const AccessFailure('request_changed');
    }
    if (command.action == InformationApprovalAction.approve &&
        command.fields.any(
          (f) =>
              !request.fields.contains(f) ||
              _service._field(f) == null ||
              _service._field(f)!.kind == FieldKind.file,
        )) {
      throw const AccessFailure('invalid_scope');
    }
    // Block competing legacy owner decisions and reads before any await.
    request.informationDecisionPending = true;
    _InformationDecision? decision;
    try {
      await _service._auditWrites;
      if (_service._auditFailed) throw const AccessFailure('audit_unavailable');
      final revision =
          await repository.informationApprovalRevision(request.id) + 1;
      _service._expire(request);
      final now = _service._clock();
      // These public facts were captured when the request was registered. Close
      // may have cleared maps during the awaits, in which case no commit starts.
      if (!_service._sessionActive(request.session) ||
          request.state != expected) {
        throw const AccessFailure('request_changed');
      }
      GrantHistory? grant;
      if (command.action == InformationApprovalAction.approve) {
        grant = GrantHistory(
          id: _service._secret(),
          requestId: request.id,
          sessionId: _service._sessionBindings[request.session]!,
          chatLabel: _service._sessions[request.session]!,
          approvedAt: now,
          expiresAt: now.add(command.lifetime),
          fields: command.fields.map((ref) {
            final item = information.firstWhere((i) => i.id == ref.itemId);
            final field = item.fields.firstWhere((f) => f.id == ref.fieldId);
            return RecordedField(item.id, field.id, item.name, field.name);
          }),
          events: [GrantEvent(GrantEventKind.approved, now)],
        );
      } else if (command.action == InformationApprovalAction.revoke) {
        grant = request.history!.finish(GrantEventKind.revoked, now);
      }
      final change = InformationApprovalCommit(
        receipt: InformationApprovalReceipt(
          operationId: command.operationId,
          requestId: request.id,
          action: command.action,
          reviewToken: command.reviewToken,
          commandDigest: command.commandDigest,
          revision: revision,
          recordedAt: now,
        ),
        request: RequestHistory(
          id: request.id,
          sessionId: _service._sessionBindings[request.session]!,
          chatLabel: _service._sessions[request.session]!,
          purpose: request.purpose,
          createdAt: request.createdAt,
          requestExpiresAt: request.expiresAt,
          recordedAt: now,
          state: switch (command.action) {
            InformationApprovalAction.approve => AccessRequestState.approved,
            InformationApprovalAction.deny => AccessRequestState.denied,
            InformationApprovalAction.revoke => AccessRequestState.revoked,
          },
          fields: request.recordedFields,
          grantId: grant?.id,
        ),
        grant: grant,
        itemVersions: command.itemVersions,
      );
      decision = _InformationDecision(_service, request, change);
      decision.validate();
      try {
        await repository.commitInformationApproval(
          change,
          validate: decision.validate,
        );
      } on Object {
        // The write can have committed before its response failed. Resolve only
        // by durable identity; while lookup fails every old/new bearer is blocked.
        _service._uncertainInformationDecisions[command.operationId] = decision;
        try {
          await _resolveInformationDecision(command.operationId, decision);
        } on Object {
          throw const AccessFailure('decision_unknown');
        }
        rethrow;
      }
      decision.settle(committed: true, uncertain: false);
      await _service._auditWrites;
      if (_service._auditFailed) throw const AccessFailure('audit_unavailable');
      return change.receipt;
    } finally {
      if (!_service._uncertainInformationDecisions.containsKey(
            command.operationId,
          ) &&
          request.informationDecisionPending) {
        request.informationDecisionPending = false;
        // A terminal event before change construction also needs an audit. The
        // public request identity is retained separately for close-time recording.
        _service._recordDeferredInformationRequest(request);
      }
    }
  }
}
