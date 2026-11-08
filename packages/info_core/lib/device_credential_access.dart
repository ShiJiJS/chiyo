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

  Map<String, Object?> _encodeDeviceCredentialRequests() => {
    'version': 2,
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
            : raw['version'] != 2 || raw.length != 3) ||
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
    if (rows.isEmpty && operations.isEmpty) return;
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
            )
            ..state = AccessRequestState.approved
            ..approvedAt = r.decidedAt
            ..recordedFields = grant.fields
            ..history = grant
            ..grant = proof;
      service._requests[r.id] = request;
      service._grants[proof.token] = request;
    }
  }
}
