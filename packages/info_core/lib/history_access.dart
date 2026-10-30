part of 'info_core.dart';

extension _AuditService on InformationService {
  void _recordRequest(
    _Request request, {
    bool sessionEnded = false,
    bool applicationClosed = false,
  }) {
    if (request.state == AccessRequestState.pending) return;
    request.decisionSessionEnded |=
        sessionEnded || _endedSessions.contains(request.session);
    request.decisionApplicationClosed |= applicationClosed;
    final history = RequestHistory(
      id: request.id,
      sessionId: _sessionBindings[request.session]!,
      chatLabel: _sessions[request.session]!,
      purpose: request.purpose,
      createdAt: request.createdAt,
      requestExpiresAt: request.expiresAt,
      recordedAt: _clock(),
      state: request.state,
      fields: request.recordedFields,
      grantId: request.history?.id,
      sessionEnded: sessionEnded || _endedSessions.contains(request.session),
      applicationClosed: applicationClosed,
    );
    if (request.informationDecisionPending) {
      request.deferredDecisionRequest = history;
    } else {
      _enqueueAudit(() => _repository.saveRequestHistory(history));
    }
  }

  void _recordDeferredInformationRequest(_Request request) {
    final history = request.deferredDecisionRequest;
    request.deferredDecisionRequest = null;
    if (history == null) return;
    final grant = request.history;
    _enqueueAudit(() async {
      if (grant != null) await _repository.saveGrantHistory(grant);
      await _repository.saveRequestHistory(history);
    });
  }

  void _recoverAudit() {
    for (final history in _repository.grantHistory.where((g) => g.active)) {
      final expired = !_clock().isBefore(history.expiresAt);
      final finished = history.finish(
        expired ? GrantEventKind.expired : GrantEventKind.applicationClosed,
        expired ? history.expiresAt : _clock(),
      );
      _enqueueAudit(() => _repository.saveGrantHistory(finished));
    }
    _pruneAudit();
  }

  bool _endedOrganization(OrganizationTask task) =>
      switch (owner.organizationState(task)) {
        OrganizationTaskState.pending ||
        OrganizationTaskState.active ||
        OrganizationTaskState.proposed => false,
        _ => true,
      };

  void _pruneAudit() => _enqueueAudit(() async {
    final cutoff = _clock().subtract(Duration(days: owner.auditRetentionDays));
    await _repository.pruneAudit(cutoff);
    // Proposed results still await an owner decision. Live tasks keep their
    // capability; only ended facts are subject to audit-history cleanup.
    await _repository.pruneOrganizationHistory({
      for (final task in _repository.organizationTasks)
        if (_endedOrganization(task) &&
            (task.approvedAt ?? task.createdAt).isBefore(cutoff))
          task.id,
    });
  });

  void _approveHistory(_Request request) {
    final grant = request.grant!;
    final history = GrantHistory(
      id: _secret(),
      requestId: request.id,
      sessionId: _sessionBindings[request.session]!,
      chatLabel: _sessions[request.session]!,
      approvedAt: request.approvedAt!,
      expiresAt: grant.expiresAt,
      fields: grant.fields.map((ref) {
        final item = _repository.items.firstWhere((i) => i.id == ref.itemId);
        final field = item.fields.firstWhere((f) => f.id == ref.fieldId);
        return RecordedField(item.id, field.id, item.name, field.name);
      }),
      events: [GrantEvent(GrantEventKind.approved, request.approvedAt!)],
    );
    request.history = history;
    _enqueueAudit(() => _repository.saveGrantHistory(history));
  }

  void _finishHistory(_Request request, GrantEventKind kind) {
    final history = request.history;
    if (history == null || !history.active) return;
    final finished = history.finish(
      kind,
      kind == GrantEventKind.expired ? history.expiresAt : _clock(),
    );
    request.history = finished;
    if (!request.informationDecisionPending) {
      _enqueueAudit(() => _repository.saveGrantHistory(finished));
    }
  }

  void _enqueueAudit(Future<void> Function() write) {
    _auditPending.add(write);
    _auditWrites = _auditWrites.then((_) async {
      if (_auditFailed) return;
      try {
        while (_auditPending.isNotEmpty) {
          await _auditPending.first();
          _auditPending.removeAt(0);
        }
      } on Object {
        _auditFailed = true;
      }
    });
  }

  Future<String> _readWithAudit(_Request? request, FieldRef target) async {
    if (_closed || _backupBusy) {
      throw const AccessFailure('service_unavailable');
    }
    final allowed = _canRead(request, target);
    // Unknown caller-supplied identifiers are not copied to the audit store.
    // A request without a recognized bearer is deliberately not associated
    // with a private target, even if the supplied name happens to exist.
    final known = request == null ? null : _field(target);
    final previouslyApproved =
        request?.history?.fields.any(
          (field) =>
              field.itemId == target.itemId && field.fieldId == target.fieldId,
        ) ??
        false;
    final normalized = known != null || previouslyApproved;
    final recorded = request?.history?.fields
        .where((f) => f.itemId == target.itemId && f.fieldId == target.fieldId)
        .firstOrNull;
    final namedItem = normalized
        ? _repository.items.where((i) => i.id == target.itemId).firstOrNull
        : null;
    var record = AccessRecord(
      id: _secret(),
      at: _clock(),
      outcome: !allowed
          ? AccessOutcome.unauthorized
          : known?.kind == FieldKind.file
          ? AccessOutcome.fileDeliveryRequired
          : AccessOutcome.allowed,
      sessionId: request?.history?.sessionId,
      grantId: request?.history?.id,
      itemId: normalized ? target.itemId : null,
      fieldId: normalized ? target.fieldId : null,
      itemName: recorded?.itemName ?? namedItem?.name,
      fieldName: recorded?.fieldName ?? known?.name,
    );
    _enqueueAudit(() => _repository.saveAccessRecord(record));
    _pruneAudit();
    await _auditWrites;
    final deliver = allowed && _canRead(request, target);
    if (allowed && !deliver) {
      // Permission may end while durable recording is pending. No value is delivered;
      // replace that operation's provisional allowed fact before returning.
      record = AccessRecord(
        id: record.id,
        at: record.at,
        outcome: AccessOutcome.unauthorized,
        sessionId: record.sessionId,
        grantId: record.grantId,
        itemId: record.itemId,
        fieldId: record.fieldId,
        itemName: record.itemName,
        fieldName: record.fieldName,
      );
      _enqueueAudit(() => _repository.saveAccessRecord(record));
      await _auditWrites;
    }
    if (_auditFailed) {
      // This read did not disclose a value. The pending write is retained and
      // records that result when the owner retries after repairing storage.
      record = AccessRecord(
        id: record.id,
        at: record.at,
        outcome: AccessOutcome.auditUnavailable,
        sessionId: record.sessionId,
        grantId: record.grantId,
        itemId: record.itemId,
        fieldId: record.fieldId,
        itemName: record.itemName,
        fieldName: record.fieldName,
      );
      _enqueueAudit(() => _repository.saveAccessRecord(record));
      throw const AccessFailure('audit_unavailable');
    }
    if (!deliver) throw const AccessFailure('unauthorized');
    if (_field(target)!.kind == FieldKind.file) {
      throw const AccessFailure('file_delivery_required');
    }
    // No await separates the final permission check and completing the value.
    // This is the read's delivery point in the core's owning isolate.
    return _field(target)!.value;
  }
}

extension OwnerAuditAccess on OwnerAccess {
  /// Owner-only current scope projection, using the actual read decision.
  /// A historical grant ID or restored field name cannot create authorization.
  bool canReadGrantedField(GrantHistory grant, FieldRef field) {
    if (grant.restoredAt != null || auditStorageUnavailable) return false;
    final request = _service._requests[grant.requestId];
    return request?.history?.id == grant.id &&
        _service._canRead(request, field);
  }

  bool get auditStorageUnavailable =>
      _service._auditFailed || _service._pendingExecutionReceipts.isNotEmpty;
  Future<void> retryAuditStorage() async {
    if (_service._backupBusy) throw const AccessFailure('service_unavailable');
    await _retryAuditStorage();
  }

  Future<void> _retryAuditStorage() async {
    await _service._auditWrites;
    _service._auditFailed = false;
    _service._enqueueAudit(() async {});
    await _service._auditWrites;
    if (_service._auditFailed) throw const AccessFailure('audit_unavailable');
  }

  int get auditRetentionDays =>
      _service._repository.readSetting('auditRetentionDays') ?? 90;

  Future<AuditHistory> history() async {
    if (_service._backupBusy) throw const AccessFailure('service_unavailable');
    for (final request in _service._requests.values) {
      _service._expire(request);
    }
    _service._pruneAudit();
    await _service._auditWrites;
    if (_service._auditFailed) throw const AccessFailure('audit_unavailable');
    return AuditHistory(
      _service._repository.grantHistory,
      _service._repository.accessRecords,
      _service._repository.requestHistory,
      _service._repository.organizationTasks.where(
        (t) =>
            organizationState(t) != OrganizationTaskState.pending &&
            !(t.approvedAt ?? t.createdAt).isBefore(
              _service._clock().subtract(Duration(days: auditRetentionDays)),
            ),
      ),
    );
  }

  Future<AuditRetentionPreview> previewAuditRetention(int days) async {
    if (![30, 90, 180, 365].contains(days)) {
      throw const AccessFailure('invalid_retention');
    }
    final current = await history();
    final cutoff = _service._clock().subtract(Duration(days: days));
    final credentialIds = _service._credentialHistoryPruneIds(cutoff);
    final preview = AuditRetentionPreview(
      days,
      current.grants.where((g) => g.approvedAt.isBefore(cutoff)).length,
      current.accesses.where((a) => a.at.isBefore(cutoff)).length,
      cutoff,
      current.requests.where((r) => r.createdAt.isBefore(cutoff)).length,
      current.organizations
          .where(
            (t) =>
                _service._endedOrganization(t) &&
                (t.approvedAt ?? t.createdAt).isBefore(cutoff),
          )
          .length,
      credentialIds.length,
      _service._repository is CredentialRuntimeRepository
          ? (_service._repository as CredentialRuntimeRepository)
                    .credentialExecutions
                    .where((e) => credentialIds.contains(e.requestId))
                    .length +
                (_service._repository is FocusedFillRuntimeRepository
                    ? (_service._repository as FocusedFillRuntimeRepository)
                          .focusedFillOperations
                          .where((o) => credentialIds.contains(o.requestId))
                          .length
                    : 0)
          : 0,
    );
    _service._retentionPreview = preview;
    return preview;
  }

  Future<void> setAuditRetention(
    int days, {
    AuditRetentionPreview? confirmation,
  }) => _serialize(() async {
    if (![30, 90, 180, 365].contains(days)) {
      throw const AccessFailure('invalid_retention');
    }
    if (days < auditRetentionDays &&
        (confirmation == null ||
            !identical(confirmation, _service._retentionPreview) ||
            confirmation.days != days)) {
      throw const AccessFailure('retention_confirmation_required');
    }
    _service._retentionPreview = null;
    await _service._repository.writeSetting('auditRetentionDays', days);
    await history();
    await _service._pruneCredentialUseHistory(
      _service._clock().subtract(Duration(days: days)),
    );
  });

  Future<void> revokeFromHistory(String grantId) async {
    final history = await this.history();
    final matches = history.grants.where((g) => g.id == grantId);
    if (matches.isEmpty || !matches.single.active) {
      throw const AccessFailure('invalid_request');
    }
    revoke(matches.single.requestId);
    await _service._auditWrites;
    if (_service._auditFailed) throw const AccessFailure('audit_unavailable');
  }
}
