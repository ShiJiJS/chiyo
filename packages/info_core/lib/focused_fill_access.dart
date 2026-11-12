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
  }) => _serializeRuntimeWrite(() async {
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
  });

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
    List<int>? secretBytes;
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
      final result = await sendPreparedFocusedFill(
        prepared,
        secretBytes!,
        beforeBatch: () => owner._serialize(() async {
          _requireFillGrant(session, original.requestId);
          final record = _fillOperation(id);
          if (!record.inputReleased) {
            await _saveFocusedFill(
              operation: record.changed({'inputReleased': true}),
              validate: () => _requireFillGrant(session, original.requestId),
            );
          }
        }),
      );
      outcome = result.state;
      error = result.errorCode;
    } on Object catch (e) {
      error = _fillError(e);
    } finally {
      secretBytes?.fillRange(0, secretBytes.length, 0);
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
  bool get focusedFillDiscoveryAvailable =>
      focusedFillAvailable &&
      _service.focusedFillDriver is FocusedFillDiscoveryDriver;
  Future<FocusedFillTarget> discoverFocusedFillTarget(String session) async {
    if (!focusedFillDiscoveryAvailable) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    void check() {
      if (_service._closed || !_service._sessionActive(session)) {
        throw const CredentialUseFailure('session_required');
      }
      _service._fillRepository();
    }

    check();
    final target =
        await (_service.focusedFillDriver as FocusedFillDiscoveryDriver)
            .inspectTarget();
    check();
    return FocusedFillTarget.fromJson(
      Map<String, dynamic>.from(target.toJson()),
    );
  }

  bool get focusedFillAvailable =>
      _service.focusedFillDriver != null &&
      _service._repository is FocusedFillRuntimeRepository &&
      !_service._closed;
  Future<CredentialUseRequest> requestFocusedFill(
    String session,
    FocusedFillInput input,
  ) => _requestFocusedFill(
    session,
    input,
    inspector: _service.focusedFillApplicationInspector,
    available: focusedFillAvailable,
  );

  Future<CredentialUseRequest> _requestFocusedFill(
    String session,
    FocusedFillInput input, {
    required FocusedFillApplicationInspector inspector,
    required bool available,
  }) => _service.owner._serialize(() async {
    if (!available) {
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
    final application = await inspector(input.fill.application);
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
      agentName: input.agentName,
      externalChatId: input.externalChatId,
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
    final claim = await _claimFocusedFill(
      session,
      input,
      available: focusedFillAvailable,
      reserveLocalDriver: true,
    );
    if (claim.$2) {
      final operation = claim.$1;
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
    }
    return _service._publicFill(claim.$1, duplicate: !claim.$2);
  }

  Future<(FocusedFillOperation, bool)> _claimFocusedFill(
    String session,
    FocusedFillOperationInput input, {
    required bool available,
    bool reserveLocalDriver = false,
  }) => _service.owner._serialize(() async {
    final existing = _findFocusedFill(session, input);
    if (existing != null) return (existing, false);
    if (!available) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    final request = _service._requireFillGrant(session, input.requestId);
    if (_service._activeFocusedFill != null ||
        _service._fillRepository().focusedFillOperations.any(
          (o) =>
              o.state == FocusedFillState.checking &&
              _service._deviceFocusedFills.containsKey(o.id),
        )) {
      throw const CredentialUseFailure('busy');
    }
    if (_service._fillRepository().focusedFillOperations.any(
      (o) =>
          _service._credentialUseSessions[o.requestId] == session &&
          ({
            FocusedFillState.checking,
            FocusedFillState.partial,
            FocusedFillState.unknown,
          }.contains(o.state)) &&
          o.attentionAcknowledgedAt == null,
    )) {
      throw const CredentialUseFailure('fill_needs_attention');
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
    if (reserveLocalDriver) _service._activeFocusedFill = operation.id;
    return (operation, true);
  });
}

extension FocusedFillOwnerAccess on OwnerAccess {
  /// The known input outcome may be uncertain even when its terminal audit
  /// could not be saved. Keep this fact independent of recovery availability.
  FocusedFillState focusedFillOperationState(String id) {
    final record = focusedFillOperations.where((o) => o.id == id).firstOrNull;
    if (record == null) throw const CredentialUseFailure('session_mismatch');
    return record.state == FocusedFillState.checking &&
            _service._failedFillAudits.contains(id)
        ? FocusedFillState.unknown
        : record.state;
  }

  /// Owner-only recovery affordance. A live input operation cannot be cleared.
  /// A failed terminal audit is also recoverable after its native task stops.
  bool canAcknowledgeFocusedFillAttention(String id) {
    if (_service._closed || _service._backupBusy) return false;
    final record = focusedFillOperations.where((o) => o.id == id).firstOrNull;
    return record != null &&
        record.attentionAcknowledgedAt == null &&
        _service._activeFocusedFill != id &&
        ({
              FocusedFillState.partial,
              FocusedFillState.unknown,
            }.contains(record.state) ||
            record.state == FocusedFillState.checking &&
                _service._failedFillAudits.contains(id));
  }

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
