part of 'info_core.dart';

extension _FocusedFillService on InformationService {
  FocusedFillRuntimeRepository _fillRepository({bool finishing = false}) {
    if ((!finishing && _closed) ||
        _backupBusy ||
        _repository is! FocusedFillRuntimeRepository) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    return _repository as FocusedFillRuntimeRepository;
  }

  void _rejectFocusedOperationCollision(String session, String operationId) {
    if (_repository is FocusedFillRuntimeRepository &&
        (_repository as FocusedFillRuntimeRepository).focusedFillOperations.any(
          (o) =>
              o.operationId == operationId &&
              _credentialUseSessions[o.requestId] == session,
        )) {
      throw const CredentialUseFailure('operation_conflict');
    }
  }

  FocusedFillOperation _fillOperation(String id) =>
      _fillRepository(
        finishing: true,
      ).focusedFillOperations.where((o) => o.id == id).firstOrNull ??
      (throw const CredentialUseFailure('session_mismatch'));
  CredentialUseRequest _requireFillGrant(String session, String requestId) {
    final request = _sessionUseRequest(session, requestId, allowEnded: true);
    if (!request.isFocusedFill || request.protocolVersion != 2) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    _requireReusableUseGrant(request, session);
    if (request.attemptConsumed) {
      throw const CredentialUseFailure('grant_revoked');
    }
    return request;
  }

  Future<void> _saveFocusedFill({
    CredentialUseRequest? request,
    FocusedFillOperation? operation,
    void Function()? validate,
    bool finishing = false,
  }) async {
    final repo = _fillRepository(finishing: finishing);
    try {
      await repo.commitFocusedFillRuntime(
        [
          for (final old in repo.credentialUseRequests)
            if (old.id != request?.id) old,
          ?request,
        ],
        [
          for (final old in repo.focusedFillOperations)
            if (old.id != operation?.id) old,
          ?operation,
        ],
        validate: validate,
      );
    } on CredentialUseFailure {
      rethrow;
    } on Object {
      throw const CredentialUseFailure('audit_unavailable');
    }
  }

  Map<String, Object?> _publicFill(
    FocusedFillOperation operation, {
    bool duplicate = false,
  }) => {
    ...operation.toJson(),
    'duplicate': duplicate,
    if (_failedFillAudits.contains(operation.id)) ...{
      'status': 'service_unavailable',
      'fillState': 'unknown',
      'errorCode': 'audit_unavailable',
    },
  };
  String _fillError(Object error) =>
      error is CredentialUseFailure &&
          focusedFillErrorCodes.contains(error.code)
      ? error.code
      : 'fill_unknown';

  Future<void> _runFocusedFill(
    String session,
    String id,
    int libraryGeneration,
  ) async {
    PreparedFocusedFill? prepared;
    List<int>? secretBytes, units;
    var anySent = false;
    var nativeInFlight = false;
    var outcome = FocusedFillState.refused;
    String? error;
    try {
      final original = _fillOperation(id);
      _requireFillGrant(session, original.requestId);
      prepared = await focusedFillDriver!.prepare(original.application);
      if (!prepared.application.matches(original.application)) {
        throw const CredentialUseFailure('application_changed');
      }
      _preparedFocusedFill = prepared;
      secretBytes = await owner._serialize(() async {
        final request = _requireFillGrant(session, original.requestId);
        final checked = _fillOperation(
          id,
        ).changed({'checkedAt': _useTimestamp(_clock().toUtc())});
        await _saveFocusedFill(
          operation: checked,
          validate: () => _requireFillGrant(session, original.requestId),
        );
        // Read only after the checking/target audit has committed. These bytes
        // never become a result DTO, command argument, or generic HTTP output.
        final credential = _useEligible(request);
        try {
          return List<int>.of(_currentCredentialMaterial(credential).bytes);
        } on AccessFailure {
          throw const CredentialUseFailure('material_prepare_failed');
        }
      });
      final text = utf8.decode(secretBytes!);
      units = List<int>.of(text.codeUnits);
      if (units.isEmpty ||
          units.length > 4096 ||
          units.any((c) => c < 32 || c == 127)) {
        throw const CredentialUseFailure('unsupported_secret');
      }
      for (var start = 0; start < units.length;) {
        var end = min(start + 16, units.length);
        if (end < units.length &&
            units[end - 1] >= 0xd800 &&
            units[end - 1] <= 0xdbff &&
            units[end] >= 0xdc00 &&
            units[end] <= 0xdfff) {
          end--;
        }
        await owner._serialize(() async {
          _requireFillGrant(session, original.requestId);
          final record = _fillOperation(id);
          if (!record.inputReleased) {
            await _saveFocusedFill(
              operation: record.changed({'inputReleased': true}),
              validate: () => _requireFillGrant(session, original.requestId),
            );
          }
        });
        final batch = List<int>.of(units.sublist(start, end));
        FocusedFillBatchResult result;
        try {
          nativeInFlight = true;
          result = await prepared.sendBatch(batch);
          nativeInFlight = false;
        } finally {
          batch.fillRange(0, batch.length, 0);
        }
        if (result.state == FocusedFillState.sent && result.errorCode != null) {
          outcome = FocusedFillState.unknown;
          error = 'fill_unknown';
          break;
        }
        if (result.state != FocusedFillState.sent) {
          outcome = result.state == FocusedFillState.refused && anySent
              ? FocusedFillState.partial
              : result.state;
          if (outcome == FocusedFillState.checking) {
            outcome = FocusedFillState.unknown;
          }
          error =
              result.errorCode != null &&
                  focusedFillErrorCodes.contains(result.errorCode)
              ? result.errorCode
              : 'fill_unknown';
          break;
        }
        anySent = true;
        start = end;
        outcome = FocusedFillState.sent;
        error = null;
      }
    } on Object catch (e) {
      error = _fillError(e);
      // A throwing driver may already have submitted input. A confirmed
      // refusal is the only path allowed to claim zero events after release.
      outcome = nativeInFlight
          ? FocusedFillState.unknown
          : anySent
          ? FocusedFillState.partial
          : FocusedFillState.refused;
    } finally {
      secretBytes?.fillRange(0, secretBytes.length, 0);
      units?.fillRange(0, units.length, 0);
      try {
        await prepared?.close();
      } on Object {
        /* No secret or raw driver diagnostics. */
      }
      _preparedFocusedFill = null;
    }
    if (_libraryGeneration != libraryGeneration) return;
    try {
      await owner._serialize(() async {
        if (_libraryGeneration != libraryGeneration) return;
        final old = _fillOperation(id);
        await _saveFocusedFill(
          operation: old.changed({
            'fillState': outcome.name,
            'errorCode': error,
            'finishedAt': _useTimestamp(_clock().toUtc()),
          }),
          finishing: true,
        );
      });
    } on Object {
      // The durable checking/released intent remains. Queries explicitly say
      // unknown, and block new operations until owner recovery can be audited.
      if (_libraryGeneration == libraryGeneration) _failedFillAudits.add(id);
    }
  }
}

extension FocusedFillAgentAccess on AgentAccess {
  bool get focusedFillAvailable =>
      _service.focusedFillDriver != null &&
      _service._repository is FocusedFillRuntimeRepository &&
      !_service._closed;
  Future<CredentialUseRequest> requestFocusedFill(
    String session,
    FocusedFillInput input,
  ) => _service.owner._serialize(() async {
    if (!focusedFillAvailable) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    _service._fillRepository();
    if (!_service._sessionActive(session)) {
      throw const CredentialUseFailure('session_required');
    }
    final credential = _service._guardUseEligibility(
      input.credentialId,
      input.version,
      requireMaterial: false,
    );
    if (!credential.discoverable || credential.form != CredentialForm.string) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final application = await _service.focusedFillApplicationInspector(
      input.fill.application,
    );
    if (application.sha256 != input.fill.application.sha256) {
      throw const CredentialUseFailure('application_changed');
    }
    void validate() {
      if (!_service._sessionActive(session)) {
        throw const CredentialUseFailure('session_required');
      }
      _service._guardUseEligibility(
        credential.id,
        credential.version,
        generation: credential.useGeneration,
        requireMaterial: false,
      );
    }

    validate();
    final now = _service._clock().toUtc();
    final request = CredentialUseRequest(
      protocolVersion: 2,
      id: _service._secret(),
      chatLabel: _service._sessions[session]!,
      purpose: input.purpose,
      alias: input.alias,
      credentialId: credential.id,
      credentialName: credential.name,
      version: credential.version,
      useGeneration: credential.useGeneration,
      fill: FocusedFillPlan(application, input.fill.targetHint),
      createdAt: now,
      requestExpiresAt: now.add(_service._requestLifetime),
      fields: const [],
    );
    await _service._saveFocusedFill(request: request, validate: validate);
    _service._credentialUseSessions[request.id] = session;
    _service._submitted.add(request.id);
    return request;
  });

  FocusedFillOperation? _findFocusedFill(
    String session,
    FocusedFillOperationInput input,
  ) {
    final request = _service._sessionUseRequest(
      session,
      input.requestId,
      allowEnded: true,
    );
    if (!request.isFocusedFill || request.protocolVersion != 2) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    if (_service._runtimeRepository.credentialExecutions.any(
      (e) =>
          e.operationId == input.operationId &&
          _service._credentialUseSessions[e.requestId] == session,
    )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    final record = _service
        ._fillRepository()
        .focusedFillOperations
        .where(
          (o) =>
              o.operationId == input.operationId &&
              _service._credentialUseSessions[o.requestId] == session,
        )
        .firstOrNull;
    if (record != null && record.fingerprint != input.fingerprint) {
      throw const CredentialUseFailure('operation_conflict');
    }
    return record;
  }

  Map<String, Object?> focusedFillStatus(
    String session,
    FocusedFillOperationInput input,
  ) {
    final record = _findFocusedFill(session, input);
    return record == null
        ? {'protocolVersion': 2, 'status': 'not_found'}
        : _service._publicFill(record, duplicate: true);
  }

  Future<Map<String, Object?>> startFocusedFill(
    String session,
    FocusedFillOperationInput input,
  ) async {
    final claim = await _service.owner._serialize(() async {
      final existing = _findFocusedFill(session, input);
      if (existing != null) return (existing, false);
      if (!focusedFillAvailable) {
        throw const CredentialUseFailure('unsupported_capability');
      }
      final request = _service._requireFillGrant(session, input.requestId);
      if (_service._fillRepository().focusedFillOperations.any(
        (o) =>
            o.requestId == request.id &&
            ({
              FocusedFillState.checking,
              FocusedFillState.partial,
              FocusedFillState.unknown,
            }.contains(o.state)) &&
            o.attentionAcknowledgedAt == null,
      )) {
        throw const CredentialUseFailure('fill_needs_attention');
      }
      if (_service._activeFocusedFill != null) {
        throw const CredentialUseFailure('busy');
      }
      final now = _service._clock().toUtc();
      final operation = FocusedFillOperation(
        id: _service._secret(),
        requestId: request.id,
        operationId: input.operationId,
        fingerprint: input.fingerprint,
        createdAt: now,
        application: request.focusedFill!.application,
      );
      await _service._saveFocusedFill(
        request: request.changed({'attemptedAt': _useTimestamp(now)}),
        operation: operation,
        validate: () => _service._requireFillGrant(session, input.requestId),
      );
      _service._activeFocusedFill = operation.id;
      final task = _service
          ._runFocusedFill(session, operation.id, _service._libraryGeneration)
          .whenComplete(() {
            _service._focusedFillTasks.remove(operation.id);
            if (_service._activeFocusedFill == operation.id) {
              _service._activeFocusedFill = null;
            }
          });
      _service._focusedFillTasks[operation.id] = task;
      unawaited(task);
      return (operation, true);
    });
    return _service._publicFill(claim.$1, duplicate: !claim.$2);
  }
}

extension FocusedFillOwnerAccess on OwnerAccess {
  List<FocusedFillOperation> get focusedFillOperations =>
      _service._repository is FocusedFillRuntimeRepository
      ? (_service._repository as FocusedFillRuntimeRepository)
            .focusedFillOperations
      : const [];
  Future<void> acknowledgeFocusedFillAttention(String id) =>
      _serialize(() async {
        var record = _service._fillOperation(id);
        if (_service._activeFocusedFill != id &&
            _service._failedFillAudits.contains(id) &&
            record.state == FocusedFillState.checking) {
          record = record.changed({
            'fillState': 'unknown',
            'finishedAt': _useTimestamp(_service._clock().toUtc()),
            'errorCode': 'audit_unavailable',
          });
        }
        if (_service._activeFocusedFill == id ||
            !{
              FocusedFillState.partial,
              FocusedFillState.unknown,
            }.contains(record.state)) {
          throw const CredentialUseFailure('request_terminal');
        }
        if (record.attentionAcknowledgedAt != null) return;
        await _service._saveFocusedFill(
          operation: record.changed({
            'attentionAcknowledgedAt': _useTimestamp(_service._clock().toUtc()),
          }),
        );
        _service._failedFillAudits.remove(id);
      });
}
