part of 'info_core.dart';

extension _AuditService on InformationService {
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

  void _pruneAudit() => _enqueueAudit(
    () => _repository.pruneAudit(
      _clock().subtract(Duration(days: owner.auditRetentionDays)),
    ),
  );

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
    _enqueueAudit(() => _repository.saveGrantHistory(finished));
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
    var record = AccessRecord(
      id: _secret(),
      at: _clock(),
      outcome: allowed ? AccessOutcome.allowed : AccessOutcome.unauthorized,
      sessionId: request?.history?.sessionId,
      grantId: request?.history?.id,
      itemId: normalized ? target.itemId : null,
      fieldId: normalized ? target.fieldId : null,
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
      );
      _enqueueAudit(() => _repository.saveAccessRecord(record));
      throw const AccessFailure('audit_unavailable');
    }
    if (!deliver) throw const AccessFailure('unauthorized');
    // No await separates the final permission check and completing the value.
    // This is the read's delivery point in the core's owning isolate.
    return _field(target)!.value;
  }
}

extension OwnerAuditAccess on OwnerAccess {
  bool get auditStorageUnavailable => _service._auditFailed;
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
    );
  }

  Future<AuditRetentionPreview> previewAuditRetention(int days) async {
    if (![30, 90, 180, 365].contains(days)) {
      throw const AccessFailure('invalid_retention');
    }
    final current = await history();
    final cutoff = _service._clock().subtract(Duration(days: days));
    final preview = AuditRetentionPreview(
      days,
      current.grants.where((g) => g.approvedAt.isBefore(cutoff)).length,
      current.accesses.where((a) => a.at.isBefore(cutoff)).length,
      cutoff,
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
