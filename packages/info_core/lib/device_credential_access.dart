part of 'info_core.dart';

/// Online Host entry points. The authenticated gateway supplies deviceId;
/// caller JSON must never choose a different device or an approval identity.
extension DeviceCredentialAgentAccess on AgentAccess {
  Future<CredentialUseRequest> requestDeviceCredentialUse(
    String deviceId,
    String session,
    CredentialUseInput input,
    DeviceCredentialLaunch prepared,
  ) async {
    if (!_service._deviceFileDelivery || input.protocolVersion != 2) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(deviceId)) {
      throw const CredentialUseFailure('session_mismatch');
    }
    final resolved = prepared.resolve(input.launch);
    final request = await _requestCredentialUse(session, input, (
      value,
      credential,
    ) {
      final delivery = _validateCredentialReceiver(value, credential);
      return delivery.resolved(resolved.executable, resolved.cwd);
    });
    _service._deviceCredentialRequests[request.id] = deviceId;
    return request;
  }

  CredentialUseRequest checkDeviceCredentialRequest(
    String deviceId,
    String session,
    String requestId, {
    bool allowEnded = false,
  }) {
    if (!_service._deviceFileDelivery ||
        _service._deviceCredentialRequests[requestId] != deviceId) {
      throw const CredentialUseFailure('session_mismatch');
    }
    return _service._sessionUseRequest(
      session,
      requestId,
      allowEnded: allowEnded,
    );
  }
}

extension _DeviceCredentialMaintenance on OnlineInformationRuntime {
  Future<void> _maintainDeviceCredentialRequests() async {
    if (service._deviceCredentialRequests.isEmpty) return;
    for (final request in service._runtimeRepository.credentialUseRequests) {
      if (!service._deviceCredentialRequests.containsKey(request.id)) continue;
      if (request.state == 'pending' &&
          !service._clock().isBefore(request.requestExpiresAt)) {
        await service._saveUse(request: request.changed({'state': 'expired'}));
      } else if (request.credentialApproved &&
          request.invalidatedCode == null &&
          request.credentialGrantExpired(service._clock())) {
        // Remember observed expiry even if the wall clock is later corrected.
        await service._saveUse(
          request: request.changed({'invalidatedCode': 'grant_expired'}),
        );
      }
    }
    for (final execution in service._runtimeRepository.credentialExecutions) {
      if (!service._deviceCredentialRequests.containsKey(execution.requestId) ||
          service._deviceCredentialExecutions.containsKey(execution.id) ||
          !{'preparing', 'running'}.contains(execution.state)) {
        continue;
      }
      if (execution.state == 'running') {
        throw const FormatException('Missing device execution proof');
      }
      // A crash before publishing/checkpointing the first material response.
      // Keep the operation consumed and uncertain, never reconstruct material.
      await service._saveUse(
        execution: execution.changed({
          'executionState': 'unknown',
          'errorCode': 'execution_unknown',
        }),
      );
    }
  }

  Future<void> _resolveDeviceCredentialDecisions() async {
    if (service._onlineCredentialDecisions.isEmpty) return;
    final repository = service._repository;
    if (repository is! AdditionalApprovalRepository) {
      throw const FormatException('Missing credential approval repository');
    }
    for (final id in service._onlineCredentialDecisions.keys.toList()) {
      InformationApprovalReceipt? receipt;
      try {
        receipt = await (repository as AdditionalApprovalRepository)
            .additionalApprovalReceipt(id);
      } on Object {
        // A failed read is not proof of absence. Retain the exact intent and
        // both read barriers, while allowing unrelated commands to continue.
        continue;
      }
      service._settleOnlineCredentialDecision(id, receipt);
    }
    _restoreDeviceCredentialFieldGrants();
    for (final intent in service._onlineCredentialDecisions.values) {
      service._requests[intent.requestId]?.informationDecisionPending = true;
    }
  }

  Map<String, Object?> _encodeDeviceCredentialRequests() => {
    'version': 3,
    'decisions': {
      for (final entry in service._onlineCredentialDecisions.entries)
        entry.key: entry.value.toJson(),
    },
    'executions': {
      for (final e in service._deviceCredentialExecutions.entries)
        e.key: e.value.toJson(),
    },
    'requests': [
      for (final entry in service._deviceCredentialRequests.entries)
        {
          'id': entry.key,
          'deviceId': entry.value,
          'session': service._credentialUseSessions[entry.key],
          'inactive': service._inactiveCredentialApprovals.contains(entry.key),
        },
    ],
  };

  void _restoreDeviceCredentialRequests(Object? raw) {
    if (raw is! Map ||
        (raw['version'] == 1
            ? raw.length != 2
            : raw['version'] == 2
            ? raw.length != 3
            : raw['version'] != 3 || raw.length != 4) ||
        raw['requests'] is! List ||
        (raw['requests'] as List).length > 100000) {
      throw const FormatException('Invalid online credential state');
    }
    final rows = raw['requests'] as List;
    final operations = raw['version'] == 1
        ? <String, dynamic>{}
        : raw['executions'];
    if (operations is! Map || operations.length > 100000) {
      throw const FormatException('Invalid device executions');
    }
    final decisions = raw['version'] == 3
        ? raw['decisions']
        : <String, dynamic>{};
    if (decisions is! Map || decisions.length > 100000) {
      throw const FormatException('Invalid online credential decisions');
    }
    if (rows.isEmpty && operations.isEmpty && decisions.isEmpty) return;
    if (service._repository is! CredentialRuntimeRepository) {
      throw const FormatException('Missing online credential repository');
    }
    final facts = {
      for (final r in service._runtimeRepository.credentialUseRequests) r.id: r,
    };
    for (final value in rows) {
      if (value is! Map ||
          value.length != 4 ||
          value['id'] is! String ||
          value['deviceId'] is! String ||
          value['session'] is! String ||
          value['inactive'] is! bool ||
          !RegExp(
            r'^[A-Za-z0-9_-]{22}$',
          ).hasMatch(value['deviceId'] as String)) {
        throw const FormatException('Invalid online credential binding');
      }
      final id = value['id'] as String, session = value['session'] as String;
      final fact = facts[id];
      if (fact == null ||
          fact.protocolVersion != 2 ||
          fact.isFocusedFill ||
          fact.restoredAt != null ||
          !service._sessions.containsKey(session) ||
          fact.chatLabel != service._sessions[session] ||
          service._deviceCredentialRequests.containsKey(id)) {
        throw const FormatException('Inconsistent online credential binding');
      }
      service._deviceCredentialRequests[id] = value['deviceId'] as String;
      service._credentialUseSessions[id] = session;
      if (value['inactive'] as bool) {
        service._inactiveCredentialApprovals.add(id);
      }
    }
    final pendingRequests = <String>{};
    for (final entry in decisions.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid online credential decision');
      }
      final command = InformationApprovalReceipt.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (command.operationId != entry.key ||
          !service._deviceCredentialRequests.containsKey(command.requestId) ||
          !pendingRequests.add(command.requestId) ||
          (command.action != InformationApprovalAction.revoke &&
              !service._inactiveCredentialApprovals.contains(
                command.requestId,
              ))) {
        throw const FormatException('Inconsistent online credential decision');
      }
      service._onlineCredentialDecisions[command.operationId] = command;
    }
    final executions = {
      for (final e in service._runtimeRepository.credentialExecutions) e.id: e,
    };
    final proofs = <String>{};
    for (final entry in operations.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid device execution');
      }
      final id = entry.key as String;
      final proof = _DeviceCredentialExecution.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      final record = executions[id];
      if (record == null ||
          record.restoredAt != null ||
          record.protocolVersion != 2 ||
          record.materialLease != null ||
          record.supervisorPid != null ||
          record.workerPid != null ||
          service._deviceCredentialRequests[record.requestId] !=
              proof.deviceId ||
          record.jobName == null ||
          !_DeviceCredentialExecution.validJob(record.jobName!) ||
          !proofs.add(proof.capability)) {
        throw const FormatException('Inconsistent device execution');
      }
      service._deviceCredentialExecutions[id] = proof;
      service._executionCapabilities[id] = proof.capability;
    }
  }

  void _restoreDeviceCredentialFieldGrants() {
    if (service._deviceCredentialRequests.isEmpty) return;
    final requests = {
      for (final r in service._repository.requestHistory) r.id: r,
    };
    final grants = {for (final g in service._repository.grantHistory) g.id: g};
    for (final r in service._runtimeRepository.credentialUseRequests) {
      final session = service._credentialUseSessions[r.id];
      if (!service._deviceCredentialRequests.containsKey(r.id) ||
          service._requests.containsKey(r.id) ||
          r.approvedFields.isEmpty ||
          service._inactiveCredentialApprovals.contains(r.id)) {
        continue;
      }
      final history = requests[r.id];
      final grant = history == null ? null : grants[history.grantId];
      if (history == null ||
          grant == null ||
          !grant.active ||
          history.state != AccessRequestState.approved) {
        continue;
      }
      final fields = r.approvedFields.toSet();
      final recorded = grant.fields
          .map((f) => FieldRef(f.itemId, f.fieldId))
          .toSet();
      if (session == null ||
          history.restoredAt != null ||
          grant.restoredAt != null ||
          history.sessionId != service._sessionBindings[session] ||
          grant.sessionId != history.sessionId ||
          grant.requestId != r.id ||
          history.createdAt != r.createdAt ||
          history.requestExpiresAt != r.requestExpiresAt ||
          history.purpose != r.purpose ||
          grant.approvedAt != r.decidedAt ||
          grant.expiresAt != r.fieldExpiresAt ||
          fields.length != recorded.length ||
          !fields.containsAll(recorded) ||
          !r.fields.toSet().containsAll(fields)) {
        throw const FormatException(
          'Inconsistent online credential field grant',
        );
      }
      // The approval transaction may have committed just before the process
      // stopped, before publishing its field proof into the private snapshot.
      // Recover only that exact committed scope and deadline.
      final proof = ClaimedGrant(
        service._secret(),
        r.approvedFields,
        grant.expiresAt,
      );
      final request =
          _Request(
              r.id,
              session,
              r.purpose,
              r.fields.toSet(),
              r.createdAt,
              r.requestExpiresAt,
              agentName: r.agentName,
              externalChatId: r.externalChatId,
            )
            ..state = AccessRequestState.approved
            ..approvedAt = r.decidedAt
            ..recordedFields = grant.fields
            ..history = grant
            ..grant = proof;
      service._requests[r.id] = request;
      service._grants[proof.token] = request;
      if (service._endedSessions.contains(session)) {
        // The scope may settle only after the chat ended while its decision
        // was unknown. Preserve the exact decision as history, never revive it.
        request.state = AccessRequestState.revoked;
        service._finishHistory(request, GrantEventKind.ended);
        service._recordRequest(request, sessionEnded: true);
      }
    }
  }
}

/// Only the online host persists uncertain owner decisions. Local adapters keep
/// their existing conservative diagnostic behavior.
extension _OnlineCredentialDecisionService on InformationService {
  bool _onlineCredentialDecisionPending(String requestId) =>
      _onlineCredentialDecisions.values.any((v) => v.requestId == requestId);

  void _rememberOnlineCredentialDecision(
    AdditionalApprovalOperation operation,
  ) {
    if (!_deviceFileDelivery ||
        !_deviceCredentialRequests.containsKey(operation.command.requestId)) {
      return;
    }
    final command = operation.command;
    if (_onlineCredentialDecisionPending(command.requestId) &&
        !_onlineCredentialDecisions.containsKey(command.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    _onlineCredentialDecisions[command.operationId] = command;
  }

  void _settleOnlineCredentialDecision(
    String id,
    InformationApprovalReceipt? receipt,
  ) {
    final intent = _onlineCredentialDecisions[id];
    if (intent == null) return;
    if (receipt != null) {
      _checkAdditionalReceipt(receipt, intent);
      if (receipt.operationId != id ||
          receipt.recordedAt != intent.recordedAt ||
          jsonEncode(receipt.metadata) != jsonEncode(intent.metadata)) {
        throw const FormatException('Inconsistent credential decision receipt');
      }
      final fact = _useRequest(intent.requestId);
      final matches = switch (intent.action) {
        InformationApprovalAction.approve => {
          'approved',
          'partially_approved',
        }.contains(fact.state),
        InformationApprovalAction.deny => fact.state == 'denied',
        InformationApprovalAction.revoke =>
          fact.invalidatedCode == 'grant_revoked',
      };
      if (!matches || fact.restoredAt != null) {
        throw const FormatException('Inconsistent credential decision fact');
      }
    } else {
      final fact = _useRequest(intent.requestId);
      // An absent receipt cannot contradict an already committed terminal fact.
      // Do not reactivate permission merely because a receipt was lost/pruned.
      if (intent.action == InformationApprovalAction.revoke
          ? fact.invalidatedCode == 'grant_revoked'
          : {'approved', 'partially_approved', 'denied'}.contains(fact.state)) {
        throw const FormatException('Missing credential decision receipt');
      }
    }
    // Online recovery uses durable facts, not the old process's closure. The
    // latter can overwrite a chat end/expiry latched while readback was down.
    _uncertainCredentialDecisions.remove(id);
    _inactiveCredentialApprovals.remove(intent.requestId);
    _onlineCredentialDecisions.remove(id);
    final request = _requests[intent.requestId];
    if (receipt != null && intent.action == InformationApprovalAction.revoke) {
      _scheduleInformationDeliveryCleanup();
    }
    if (request != null) {
      final deferred = request.deferredDecisionRequest != null;
      request.deferredDecisionRequest = null;
      request.informationDecisionPending = false;
      // Durable terminal facts still win after reopen or delayed readback.
      final history = _repository.requestHistory
          .where((r) => r.id == intent.requestId)
          .firstOrNull;
      if (history != null) {
        request.state = history.state;
        request.history = _repository.grantHistory
            .where((g) => g.id == history.grantId)
            .firstOrNull;
      }
      final ended =
          request.decisionSessionEnded ||
          _endedSessions.contains(request.session);
      if (ended) {
        if (request.state == AccessRequestState.approved) {
          request.state = AccessRequestState.revoked;
        }
        _finishHistory(request, GrantEventKind.ended);
      }
      _expire(request);
      if (deferred || ended) _recordRequest(request, sessionEnded: ended);
    }
  }
}
