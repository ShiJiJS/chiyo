part of 'info_core.dart';

extension _CredentialBatchService on InformationService {
  CredentialBatchRepository get _batchRepository {
    if (_closed || _backupBusy || _repository is! CredentialBatchRepository) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    return _repository as CredentialBatchRepository;
  }

  CredentialUseBatch _batchRequest(String id) =>
      _batchRepository.credentialBatches.where((r) => r.id == id).firstOrNull ??
      (throw const CredentialUseFailure('session_mismatch'));
  CredentialUseBatch _sessionBatch(String session, String deviceId, String id) {
    _requireSession(session);
    final r = _batchRequest(id);
    if (r.archived ||
        r.deviceId != deviceId ||
        r.sessionBinding != _sessionBindings[session]) {
      throw const CredentialUseFailure('session_mismatch');
    }
    return r;
  }

  String? _batchSession(CredentialUseBatch r) => _sessionBindings.entries
      .where((e) => e.value == r.sessionBinding)
      .map((e) => e.key)
      .firstOrNull;
  void _requireBatchItem(CredentialUseBatch r, CredentialBatchItem item) {
    r = _batchRequest(r.id);
    item =
        r.items.where((current) => current.id == item.id).firstOrNull ??
        (throw const CredentialUseFailure('scope_not_approved'));
    final session = _batchSession(r);
    if (r.archived || session == null || !_sessionActive(session)) {
      throw const CredentialUseFailure('grant_revoked');
    }
    if (item.decision == CredentialBatchItemDecision.pending) {
      throw const CredentialUseFailure('request_pending');
    }
    if (item.decision != CredentialBatchItemDecision.approved) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    if (item.expiresAt != null && !_clock().isBefore(item.expiresAt!)) {
      throw const CredentialUseFailure('grant_expired');
    }
    if (item.destination.ssh case final ssh?) {
      if (ssh.trustId != _sshHostTrust?.id ||
          ssh.trustHash != _sshHostTrust?.sha256) {
        throw const CredentialUseFailure('receiver_not_ready');
      }
    }
    _guardUseEligibility(
      item.credentialId,
      item.version,
      generation: item.useGeneration,
      requireMaterial: false,
    );
  }

  String _batchItemState(CredentialUseBatch r, CredentialBatchItem item) {
    if (item.decision == CredentialBatchItemDecision.pending) {
      return _clock().isBefore(r.requestExpiresAt) ? 'pending' : 'expired';
    }
    if (item.decision == CredentialBatchItemDecision.denied) return 'denied';
    if (item.decision == CredentialBatchItemDecision.revoked) return 'revoked';
    try {
      _requireBatchItem(r, item);
      return 'available';
    } on CredentialUseFailure catch (error) {
      return switch (error.code) {
        'grant_expired' || 'credential_expired' => 'expired',
        'credential_version_changed' => 'version_invalidated',
        _ => 'revoked',
      };
    }
  }

  String _batchState(CredentialUseBatch r) {
    if (r.archived) return 'ended';
    if (r.decisions.isEmpty) {
      final session = _batchSession(r);
      if (session == null || !_sessionActive(session)) return 'cancelled';
      return _clock().isBefore(r.requestExpiresAt) ? 'pending' : 'expired';
    }
    final approved = r.items
        .where((i) => i.decision == CredentialBatchItemDecision.approved)
        .length;
    if (approved == r.items.length) return 'approved';
    if (approved > 0) return 'partially_approved';
    return r.items.any((i) => i.decision == CredentialBatchItemDecision.revoked)
        ? 'revoked'
        : 'denied';
  }

  List<CredentialBatchItem> _selectedBatchItems(
    CredentialUseBatch r,
    Iterable<String>? ids,
  ) {
    final selected = ids?.toList() ?? r.items.map((i) => i.id).toList();
    if (selected.isEmpty ||
        selected.length > 20 ||
        selected.toSet().length != selected.length ||
        selected.any((id) => !r.items.any((i) => i.id == id))) {
      throw const CredentialUseFailure('invalid_reference');
    }
    return r.items.where((i) => selected.contains(i.id)).toList();
  }

  CredentialBatchOperation? _batchOperation(String binding, String id) =>
      _batchRepository.credentialBatchOperations
          .where((o) => o.sessionBinding == binding && o.operationId == id)
          .firstOrNull;
  CredentialBatchOperation _batchOperationForDisplay(
    CredentialBatchOperation operation,
  ) =>
      {
            CredentialBatchOperationState.checking,
            CredentialBatchOperationState.dispatched,
          }.contains(operation.state) &&
          !_clock().isBefore(
            operation.createdAt.add(const Duration(seconds: 30)),
          )
      ? operation.changed(
          state: CredentialBatchOperationState.unknown,
          errorCode: 'execution_unknown',
        )
      : operation;
  String _batchDestinationKey(CredentialBatchDestination destination) =>
      destination.ssh != null
      ? _useFingerprint(destination.toJson())
      : destination.native != null
      ? _useFingerprint({
          'via': 'native',
          'helper': destination.native!.helperInstanceId,
          'target': destination.native!.targetId,
        })
      : destination.application != null
      ? 'native-focus'
      : _useFingerprint({
          'via': destination.via,
          'instanceId': destination.browser!.instanceId,
          'pageId': destination.browser!.pageId,
          'space': destination.browser!.space,
          'browser': destination.browser!.browserAddress,
        });
  (_CredentialBatchProof, CredentialUseBatch, CredentialBatchOperation)
  _batchProof(String deviceId, String proof, {bool requireActive = true}) {
    final capability = _batchMaterialProofs[proof];
    if (capability == null || capability.deviceId != deviceId) {
      throw const CredentialUseFailure('session_mismatch');
    }
    final operation = _batchOperation(
      capability.sessionBinding,
      capability.operationId,
    );
    if (operation == null) throw const CredentialUseFailure('session_mismatch');
    final request = _batchRequest(operation.requestId);
    if (request.deviceId != deviceId ||
        request.sessionBinding != capability.sessionBinding) {
      throw const CredentialUseFailure('session_mismatch');
    }
    if (requireActive &&
        (!_clock().isBefore(capability.deadline) ||
            !{
              CredentialBatchOperationState.checking,
              CredentialBatchOperationState.dispatched,
            }.contains(operation.state))) {
      throw const CredentialUseFailure('execution_unknown');
    }
    return (capability, request, operation);
  }
}

extension CredentialBatchAgentAccess on AgentAccess {
  bool get credentialBatchesAvailable =>
      !_service._closed && _service._repository is CredentialBatchRepository;

  Future<CredentialUseBatch> requestCredentialBatch(
    String session,
    String deviceId,
    CredentialBatchInput input, {
    required String operationId,
  }) => _service.owner._serialize(() async {
    _service._requireSession(session);
    _batchOperationId(operationId);
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(deviceId)) {
      throw const CredentialUseFailure('session_mismatch');
    }
    final binding = _service._sessionBindings[session]!;
    final repo = _service._batchRepository;
    final previous = repo.credentialBatches
        .where(
          (r) => r.sessionBinding == binding && r.operationId == operationId,
        )
        .firstOrNull;
    if (previous != null) {
      if (previous.submissionDigest != input.fingerprint ||
          previous.deviceId != deviceId) {
        throw const CredentialUseFailure('operation_conflict');
      }
      return previous;
    }
    if (!_reserveAgentOperation(
      session,
      operationId,
      'credential-use-submit',
      _useFingerprint({'deviceId': deviceId, 'input': input.toJson()}),
    )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    if (repo.credentialBatches
            .where(
              (r) =>
                  r.sessionBinding == binding &&
                  _service._batchState(r) == 'pending',
            )
            .length >=
        20) {
      throw const CredentialUseFailure('request_limit');
    }
    final items = <CredentialBatchItem>[];
    for (final (index, candidate) in input.items.indexed) {
      final known = _service.owner.credentials
          .where((c) => c.id == candidate.credentialId)
          .firstOrNull;
      if (known == null || !known.discoverable) {
        throw const CredentialUseFailure('invalid_reference');
      }
      final c = _service._guardUseEligibility(
        known.id,
        candidate.version ?? known.version,
        requireMaterial: false,
      );
      if (candidate.destination.program case final program?) {
        if (!program.binding.acceptsForm(c.form)) {
          throw const CredentialUseFailure('invalid_reference');
        }
      } else if (candidate.destination.ssh case final ssh?) {
        if (!ssh.accepts(c.form) || _service._sshHostTrust == null) {
          throw const CredentialUseFailure('receiver_not_ready');
        }
      } else if (c.form != CredentialForm.string) {
        throw const CredentialUseFailure('invalid_reference');
      }
      items.add(
        CredentialBatchItem(
          id: 'b${index + 1}',
          credentialId: c.id,
          credentialName: c.name,
          version: c.version,
          useGeneration: c.useGeneration,
          destination: candidate.destination.ssh != null
              ? CredentialBatchDestination._(
                  'ssh',
                  null,
                  null,
                  null,
                  null,
                  candidate.destination.ssh!.trusted(_service._sshHostTrust!),
                )
              : candidate.destination.program == null
              ? candidate.destination
              : CredentialBatchDestination._(
                  'program',
                  null,
                  null,
                  CredentialProgramDestination(
                    candidate.destination.program!.executable,
                    CredentialProgramBinding._(
                      candidate.destination.program!.binding.location,
                      candidate.destination.program!.binding.via,
                      CredentialProgramReference._(c.id, c.version),
                    ),
                  ),
                ),
        ),
      );
    }
    if (items
            .map(
              (i) => _useFingerprint({
                'credentialId': i.credentialId,
                'version': i.version,
                'destination': i.destination.toJson(),
              }),
            )
            .toSet()
            .length !=
        items.length) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final now = _batchTime(_service._clock());
    final request = CredentialUseBatch(
      id: _service._secret(),
      sessionBinding: binding,
      deviceId: deviceId,
      operationId: operationId,
      submissionDigest: input.fingerprint,
      chatLabel: _service._sessions[session]!,
      agentName: input.agentName,
      externalChatId: input.externalChatId,
      purpose: input.purpose,
      title: input.title,
      createdAt: now,
      requestExpiresAt: now.add(_service._requestLifetime),
      items: items,
      programPlan: input.programPlan?.withVersions({
        for (final i in items) i.credentialId: i.version,
      }),
    );
    void validate() {
      _service._requireSession(session);
      for (final item in items) {
        _service._guardUseEligibility(
          item.credentialId,
          item.version,
          generation: item.useGeneration,
          requireMaterial: false,
        );
      }
    }

    await repo.commitCredentialBatch(
      request,
      expectedRevision: 0,
      validate: validate,
    );
    _service._submitted.add(request.id);
    return request;
  });

  Map<String, Object?> credentialBatchStatus(
    String session,
    String deviceId,
    String id,
  ) {
    final r = _service._sessionBatch(session, deviceId, id);
    return {
      'status': _service._batchState(r),
      'protocolVersion': 3,
      'requestId': r.id,
      'operationId': r.operationId,
      'purpose': r.purpose,
      if (r.title.isNotEmpty) ...{'title': r.title, 'summary': r.purpose},
      if (r.programPlan != null) 'programPlan': r.programPlan!.toJson(),
      'revision': r.revision,
      'createdAt': _useTimestamp(r.createdAt),
      'requestExpiresAt': _useTimestamp(r.requestExpiresAt),
      'items': [
        for (final item in r.items)
          {
            'id': item.id,
            'credentialId': item.credentialId,
            'name': item.credentialName,
            'version': item.version,
            'destination': item.destination.toJson(),
            'decision': item.decision.name,
            'grantState': _service._batchItemState(r, item),
            'expiresAt': _useTimestamp(item.expiresAt),
            if (_service._batchItemState(r, item) == 'available')
              'account': _service.owner.credential(item.credentialId).account,
          },
      ],
    };
  }

  Future<CredentialBatchOperationClaim> beginCredentialBatchOperation(
    String session,
    String deviceId,
    String requestId, {
    required String operationId,
    Iterable<String>? itemIds,
    SshSessionOperationContext? sshContext,
  }) => _service.owner._serialize(() async {
    _batchOperationId(operationId);
    final r = _service._sessionBatch(session, deviceId, requestId);
    if (r.programPlan != null) {
      throw const CredentialUseFailure('unsupported_receiver');
    }
    final selected = _service._selectedBatchItems(r, itemIds);
    final ssh = selected.length == 1 ? selected.single.destination.ssh : null;
    if ((sshContext != null) != (ssh != null) ||
        sshContext != null &&
            (sshContext.kind == 'credential'
                ? ssh!.credentialUse != 'sudo'
                : ssh!.credentialUse != 'login')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final ids = selected.map((i) => i.id).toList()..sort();
    final fingerprint = _useFingerprint({
      'requestId': r.id,
      if (sshContext != null) 'sshContext': sshContext.toJson(),
      'itemIds': ids,
      'destinations': [for (final item in selected) item.destination.toJson()],
    });
    final existing = _service._batchOperation(r.sessionBinding, operationId);
    if (existing != null) {
      if (existing.fingerprint != fingerprint) {
        throw const CredentialUseFailure('operation_conflict');
      }
      return CredentialBatchOperationClaim(
        _service._batchOperationForDisplay(existing),
      );
    }
    if (!_reserveAgentOperation(
      session,
      operationId,
      'credential-fill',
      fingerprint,
    )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    void validate() {
      final current = _service._sessionBatch(session, deviceId, requestId);
      if (current.revision != r.revision) {
        throw const CredentialUseFailure('operation_conflict');
      }
      for (final item in selected) {
        _service._requireBatchItem(current, item);
      }
    }

    validate();
    final targets = selected
        .map((i) => _service._batchDestinationKey(i.destination))
        .toSet();
    for (final active
        in sshContext != null
            ? <CredentialBatchOperation>[]
            : _service._batchRepository.credentialBatchOperations) {
      if (active.attentionAcknowledgedAt != null) continue;
      final observedState = _service._batchOperationForDisplay(active).state;
      if (!{
        CredentialBatchOperationState.checking,
        CredentialBatchOperationState.dispatched,
        CredentialBatchOperationState.unknown,
        CredentialBatchOperationState.partial,
      }.contains(observedState)) {
        continue;
      }
      final request = _service._batchRequest(active.requestId);
      if (request.deviceId != deviceId) continue;
      if (request.items
          .where((i) => active.itemIds.contains(i.id))
          .any(
            (i) =>
                targets.contains(_service._batchDestinationKey(i.destination)),
          )) {
        throw CredentialUseFailure(
          {
                CredentialBatchOperationState.unknown,
                CredentialBatchOperationState.partial,
              }.contains(observedState)
              ? 'fill_needs_attention'
              : 'busy',
        );
      }
    }
    final now = _batchTime(_service._clock());
    final operation = CredentialBatchOperation(
      sshContext: sshContext,
      operationId: operationId,
      requestId: r.id,
      sessionBinding: r.sessionBinding,
      fingerprint: fingerprint,
      createdAt: now,
      itemIds: ids,
    );
    await _service._batchRepository.commitCredentialBatch(
      r,
      expectedRevision: r.revision,
      operation: operation,
      expectedOperationRevision: 0,
      validate: validate,
    );
    final proof = _service._secret();
    _service._batchMaterialProofs[proof] = _CredentialBatchProof(
      operationId,
      r.sessionBinding,
      deviceId,
      proof,
      now.add(const Duration(seconds: 30)),
    );
    return CredentialBatchOperationClaim(operation, privateProof: proof);
  });

  Map<String, Object?> credentialBatchOperationStatus(
    String session,
    String deviceId,
    String operationId,
  ) {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session]!;
    final operation = _service._batchOperation(binding, operationId);
    if (operation == null) {
      return {'status': 'not_found', 'operationId': operationId};
    }
    _service._sessionBatch(session, deviceId, operation.requestId);
    return _service._batchOperationForDisplay(operation).toPublicJson();
  }

  /// Only the internal App execution channel uses the one-time proof. Collect
  /// all material before releasing any, then durably mark the claim consumed.
  Future<CredentialBatchMaterials> claimCredentialBatchMaterials(
    String deviceId,
    String proof,
    Map<String, CredentialBatchDestination> observations,
  ) => _service.owner._serialize(() async {
    final (_, r, operation) = _service._batchProof(deviceId, proof);
    if (operation.sshContext?.requiresMaterial == false ||
        operation.materialClaimed ||
        operation.state != CredentialBatchOperationState.checking) {
      throw const CredentialUseFailure('execution_unknown');
    }
    final selected = _service._selectedBatchItems(r, operation.itemIds);
    if (observations.length != selected.length) {
      throw const CredentialUseFailure('destination_changed');
    }
    void validate() {
      for (final item in selected) {
        _service._requireBatchItem(_service._batchRequest(r.id), item);
        final observed = observations[item.id];
        if (observed == null || !item.destination.matches(observed)) {
          throw const CredentialUseFailure('destination_changed');
        }
      }
    }

    validate();
    final bytes = <String, List<int>>{};
    for (final item in selected) {
      final credential = _service._guardUseEligibility(
        item.credentialId,
        item.version,
        generation: item.useGeneration,
      );
      bytes[item.id] = List<int>.of(
        _service._currentCredentialMaterial(credential).bytes,
      );
    }
    await _service._batchRepository.commitCredentialBatch(
      r,
      expectedRevision: r.revision,
      operation: operation.changed(materialClaimed: true),
      expectedOperationRevision: operation.revision,
      validate: validate,
    );
    return CredentialBatchMaterials(bytes);
  });

  Future<void> authorizeCredentialBatchInput(
    String deviceId,
    String proof, {
    String? sshLoginSession,
    String? sshLoginRequestId,
  }) => _service.owner._serialize(() async {
    final (_, r, operation) = _service._batchProof(deviceId, proof);
    if (!operation.materialClaimed &&
        operation.sshContext?.requiresMaterial != false) {
      throw const CredentialUseFailure('material_prepare_failed');
    }
    void validate() {
      if (operation.sshContext?.kind == 'credential') {
        if (sshLoginSession == null || sshLoginRequestId == null) {
          throw const CredentialUseFailure('scope_not_approved');
        }
        final login = _service._sessionBatch(
          sshLoginSession,
          deviceId,
          sshLoginRequestId,
        );
        if (login.items.length != 1 ||
            login.sessionBinding != r.sessionBinding) {
          throw const CredentialUseFailure('session_mismatch');
        }
        final loginTarget = login.items.single.destination.ssh;
        final sudoTarget = r.items.single.destination.ssh;
        if (loginTarget == null ||
            sudoTarget == null ||
            loginTarget.credentialUse != 'login' ||
            sudoTarget.credentialUse != 'sudo' ||
            loginTarget.host != sudoTarget.host ||
            loginTarget.port != sudoTarget.port ||
            loginTarget.user != sudoTarget.user ||
            loginTarget.trustId != sudoTarget.trustId ||
            loginTarget.trustHash != sudoTarget.trustHash) {
          throw const CredentialUseFailure('scope_not_approved');
        }
        _service._requireBatchItem(login, login.items.single);
      } else if (sshLoginSession != null || sshLoginRequestId != null) {
        throw const CredentialUseFailure('invalid_plan');
      }
      final current = _service._batchRequest(r.id);
      for (final item in _service._selectedBatchItems(
        current,
        operation.itemIds,
      )) {
        _service._requireBatchItem(current, item);
      }
    }

    validate();
    if (operation.state == CredentialBatchOperationState.dispatched) return;
    await _service._batchRepository.commitCredentialBatch(
      r,
      expectedRevision: r.revision,
      operation: operation.changed(
        state: CredentialBatchOperationState.dispatched,
      ),
      expectedOperationRevision: operation.revision,
      validate: validate,
    );
  });

  Future<CredentialBatchOperation> finishCredentialBatchOperation(
    String deviceId,
    String proof,
    CredentialBatchOperationState state, {
    Map<String, String> itemResults = const {},
    String? errorCode,
  }) => _service.owner._serialize(() async {
    final (_, r, operation) = _service._batchProof(
      deviceId,
      proof,
      requireActive: false,
    );
    if ({
          CredentialBatchOperationState.checking,
          CredentialBatchOperationState.dispatched,
        }.contains(state) ||
        errorCode != null && !credentialBatchErrorCodes.contains(errorCode)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (!{
      CredentialBatchOperationState.checking,
      CredentialBatchOperationState.dispatched,
    }.contains(operation.state)) {
      if (operation.state != state ||
          _useFingerprint(operation.itemResults) !=
              _useFingerprint(itemResults) ||
          operation.errorCode != errorCode) {
        throw const CredentialUseFailure('operation_conflict');
      }
      return operation;
    }
    if (state == CredentialBatchOperationState.filled &&
        (operation.state != CredentialBatchOperationState.dispatched ||
            itemResults.length != operation.itemIds.length ||
            itemResults.values.any((v) => v != 'filled' && v != 'sent'))) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (state == CredentialBatchOperationState.refused &&
        operation.state == CredentialBatchOperationState.dispatched) {
      throw const CredentialUseFailure('execution_unknown');
    }
    final next = operation.changed(
      state: state,
      itemResults: itemResults,
      errorCode: errorCode,
      finishedAt: _batchTime(_service._clock()),
    );
    CredentialBatchOperation.fromJson(Map<String, dynamic>.from(next.toJson()));
    await _service._batchRepository.commitCredentialBatch(
      r,
      expectedRevision: r.revision,
      operation: next,
      expectedOperationRevision: operation.revision,
      validate: () {},
    );
    return next;
  });
}

extension CredentialBatchOwnerAccess on OwnerAccess {
  List<CredentialUseBatch> get credentialBatches =>
      _service._batchRepository.credentialBatches;
  int get pendingCredentialBatchCount => credentialBatches
      .where((r) => _service._batchState(r) == 'pending')
      .length;
  List<CredentialBatchOperation> get credentialBatchOperations =>
      _service._batchRepository.credentialBatchOperations;
  Map<String, Object?> credentialBatchOperationView(
    CredentialBatchOperation operation,
  ) => {
    ..._service._batchOperationForDisplay(operation).toPublicJson(),
    'revision': operation.revision,
    'observedAt': _useTimestamp(_service._clock()),
  };
  String credentialBatchState(CredentialUseBatch r) => _service._batchState(r);
  String credentialBatchItemState(
    CredentialUseBatch r,
    CredentialBatchItem item,
  ) => _service._batchItemState(r, item);
  void checkCredentialBatchItemEligibility(CredentialBatchItem item) {
    _service._guardUseEligibility(
      item.credentialId,
      item.version,
      generation: item.useGeneration,
      requireMaterial: false,
    );
  }

  InformationApprovalReceipt? credentialBatchApprovalReceipt(String id) {
    for (final r in credentialBatches) {
      for (final decision in r.decisions) {
        if (decision.operationId == id) return decision.ownerReceipt;
      }
    }
    return null;
  }

  Future<CredentialBatchOperation> acknowledgeCredentialBatchOperation(
    String requestId,
    String operationId, {
    required String ownerOperationId,
    required int revision,
  }) => _serialize(() async {
    _batchOperationId(ownerOperationId);
    final repo = _service._batchRepository;
    final request = _service._batchRequest(requestId);
    if (request.archived) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    final operation = _service._batchOperation(
      request.sessionBinding,
      operationId,
    );
    if (operation == null || operation.requestId != request.id) {
      throw const CredentialUseFailure('invalid_reference');
    }
    for (final other in repo.credentialBatchOperations) {
      if (other.attentionOperationId != ownerOperationId) continue;
      if (other.requestId != requestId ||
          other.operationId != operationId ||
          other.revision != revision + 1) {
        throw const CredentialUseFailure('operation_conflict');
      }
      return other;
    }
    if (repo.credentialBatches.any(
      (r) => r.decisions.any((d) => d.operationId == ownerOperationId),
    )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    final observed = _service._batchOperationForDisplay(operation);
    if (operation.revision != revision ||
        operation.attentionAcknowledgedAt != null ||
        !{
          CredentialBatchOperationState.unknown,
          CredentialBatchOperationState.partial,
        }.contains(observed.state)) {
      throw const CredentialUseFailure('operation_conflict');
    }
    final next = operation.changed(
      state: observed.state,
      errorCode: observed.errorCode,
      attentionOperationId: ownerOperationId,
      attentionAcknowledgedAt: _batchTime(_service._clock()),
    );
    await repo.commitCredentialBatch(
      request,
      expectedRevision: request.revision,
      operation: next,
      expectedOperationRevision: operation.revision,
      validate: () {},
    );
    return next;
  });

  Future<CredentialUseBatch> decideCredentialBatch(
    String id, {
    required String operationId,
    required int revision,
    required Iterable<String> approvedItems,
    Duration? lifetime = AccessTiming.defaultLifetime,
    String? reviewToken,
    String? commandDigest,
    void Function()? validateReview,
  }) => _decideBatch(
    id,
    operationId,
    revision,
    approvedItems,
    'approve',
    lifetime,
    reviewToken,
    commandDigest,
    validateReview,
  );
  Future<CredentialUseBatch> revokeCredentialBatch(
    String id, {
    required String operationId,
    required int revision,
    required Iterable<String> itemIds,
    String? reviewToken,
    String? commandDigest,
    void Function()? validateReview,
  }) => _decideBatch(
    id,
    operationId,
    revision,
    itemIds,
    'revoke',
    null,
    reviewToken,
    commandDigest,
    validateReview,
  );

  Future<CredentialUseBatch> _decideBatch(
    String id,
    String operationId,
    int revision,
    Iterable<String> itemIds,
    String action,
    Duration? lifetime,
    String? reviewToken,
    String? commandDigest,
    void Function()? validateReview,
  ) => _serialize(() async {
    _batchOperationId(operationId);
    final repo = _service._batchRepository;
    if ((reviewToken == null) != (commandDigest == null)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final selected = itemIds.toList()..sort();
    if (selected.toSet().length != selected.length ||
        selected.length > 20 ||
        action == 'approve' &&
            lifetime != null &&
            !AccessTiming.isGrant(lifetime) ||
        action == 'revoke' && selected.isEmpty) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final fingerprint = _useFingerprint({
      'requestId': id,
      'revision': revision,
      'action': action,
      'itemIds': selected,
      'lifetimeMs': lifetime?.inMilliseconds,
      'reviewToken': ?reviewToken,
      'commandDigest': ?commandDigest,
    });
    for (final existing in repo.credentialBatches) {
      final receipt = existing.decisions
          .where((d) => d.operationId == operationId)
          .firstOrNull;
      if (receipt == null) continue;
      if (existing.id != id || receipt.fingerprint != fingerprint) {
        throw const CredentialUseFailure('operation_conflict');
      }
      return existing;
    }
    if (repo.credentialBatchOperations.any(
      (o) => o.attentionOperationId == operationId,
    )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    final r = _service._batchRequest(id);
    if (r.revision != revision ||
        r.archived ||
        selected.any((id) => !r.items.any((i) => i.id == id))) {
      throw const CredentialUseFailure('operation_conflict');
    }
    if (action == 'approve' &&
        lifetime == null &&
        r.items
            .where((i) => selected.contains(i.id))
            .any((i) => i.destination.ssh?.validity != 'session')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final now = _batchTime(_service._clock());
    void validate() {
      validateReview?.call();
      if (_service._batchRequest(id).revision != revision) {
        throw const CredentialUseFailure('operation_conflict');
      }
      if (action == 'approve') {
        if (_service._batchState(r) != 'pending') {
          throw const CredentialUseFailure('request_expired');
        }
        for (final item in r.items.where((i) => selected.contains(i.id))) {
          _service._guardUseEligibility(
            item.credentialId,
            item.version,
            generation: item.useGeneration,
            requireMaterial: false,
          );
        }
      } else if (r.items
          .where((i) => selected.contains(i.id))
          .any((i) => i.decision != CredentialBatchItemDecision.approved)) {
        throw const CredentialUseFailure('scope_not_approved');
      }
    }

    validate();
    final items = [
      for (final item in r.items)
        action == 'approve'
            ? item.decided(
                selected.contains(item.id)
                    ? CredentialBatchItemDecision.approved
                    : CredentialBatchItemDecision.denied,
                selected.contains(item.id) && lifetime != null
                    ? now.add(lifetime)
                    : null,
              )
            : selected.contains(item.id)
            ? item.decided(CredentialBatchItemDecision.revoked, item.expiresAt)
            : item,
    ];
    final next = r.withDecision(
      items,
      CredentialBatchDecisionReceipt(
        operationId,
        fingerprint,
        now,
        ownerReceipt: reviewToken == null
            ? null
            : InformationApprovalReceipt(
                operationId: operationId,
                requestId: id,
                action: action == 'revoke'
                    ? InformationApprovalAction.revoke
                    : selected.isEmpty
                    ? InformationApprovalAction.deny
                    : InformationApprovalAction.approve,
                reviewToken: reviewToken,
                commandDigest: commandDigest!,
                revision: revision + 1,
                recordedAt: now,
              ),
      ),
    );
    await repo.commitCredentialBatch(
      next,
      expectedRevision: revision,
      validate: validate,
    );
    return next;
  });
}
