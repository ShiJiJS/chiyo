part of 'info_core.dart';

/// Trusted owner action; deliberately absent from catalog/detail projections.
extension CredentialOwnerRevealAccess on OwnerAccess {
  Future<String> readStringCredential(String id, int version) => _serialize(
    () async {
      final credential = this.credential(id);
      if (credential.deletedAt != null || credential.purgedAt != null) {
        throw const AccessFailure('credential_deleted');
      }
      if (credential.version != version) {
        throw const AccessFailure('credential_version_changed');
      }
      if (credential.form != CredentialForm.string) {
        throw const AccessFailure('credential_form_mismatch');
      }
      return utf8.decode(_service._currentCredentialMaterial(credential).bytes);
    },
  );
}

class CredentialRevealRead {
  const CredentialRevealRead(this.operationId, this.at);
  final String operationId;
  final DateTime at;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'at': _useTimestamp(at),
  };
  factory CredentialRevealRead.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'operationId', 'at'});
    return CredentialRevealRead(
      _useId(json['operationId'], 'operationId'),
      DateTime.parse(json['at'] as String),
    );
  }
}

class CredentialRevealInput {
  const CredentialRevealInput._(
    this.credentialId,
    this.version,
    this.purpose,
    this.fallbackReason,
    this.agentName,
    this.externalChatId,
  );
  final String credentialId, purpose, fallbackReason, agentName, externalChatId;
  final int version;
  factory CredentialRevealInput.fromJson(Map<String, dynamic> json) {
    _useShape(
      json,
      {
        'protocolVersion',
        'command',
        'credentialId',
        'version',
        'purpose',
        'fallbackReason',
      },
      {'agentName', 'externalChatId', 'submissionVersion'},
    );
    if (json['protocolVersion'] != 2 ||
        json['command'] != 'request-reveal' ||
        json['version'] is! int ||
        (json['version'] as int) < 1) {
      throw const CredentialUseFailure('invalid_type');
    }
    final purpose = _useText(
      json['purpose'],
      'purpose',
      max: 2000,
      empty: false,
    );
    final reason = _useText(
      json['fallbackReason'],
      'fallbackReason',
      max: 2000,
      empty: false,
    );
    if (purpose.trim().isEmpty || reason.trim().isEmpty) {
      throw const CredentialUseFailure('invalid_type');
    }
    return CredentialRevealInput._(
      _useId(json['credentialId'], 'credentialId'),
      json['version'] as int,
      purpose,
      reason,
      _useSourceText(json, 'agentName'),
      _useSourceText(json, 'externalChatId'),
    );
  }
}

extension CredentialRevealAgentAccess on AgentAccess {
  Future<CredentialUseRequest> requestCredentialReveal(
    String session,
    CredentialRevealInput input,
  ) => _service.owner._serialize(() async {
    _service._runtimeRepository;
    if (!_service._sessionActive(session)) {
      throw const CredentialUseFailure('session_required');
    }
    final c = _service._guardUseEligibility(input.credentialId, input.version);
    if (!c.discoverable || c.form != CredentialForm.string) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final now = _service._clock().toUtc();
    final request = CredentialUseRequest(
      protocolVersion: 2,
      id: _service._secret(),
      chatLabel: _service._sessions[session]!,
      agentName: input.agentName,
      externalChatId: input.externalChatId,
      purpose: input.purpose,
      alias: 'credential',
      credentialId: c.id,
      credentialName: c.name,
      version: c.version,
      useGeneration: c.useGeneration,
      revealReason: input.fallbackReason,
      createdAt: now,
      requestExpiresAt: now.add(_service._requestLifetime),
      fields: const [],
    );
    void validate() {
      if (!_service._sessionActive(session)) {
        throw const CredentialUseFailure('session_required');
      }
      _service._guardUseEligibility(
        c.id,
        c.version,
        generation: c.useGeneration,
      );
    }

    await _service._saveUse(request: request, validate: validate);
    _service._credentialUseSessions[request.id] = session;
    _service._submitted.add(request.id);
    return request;
  });

  /// Plaintext can only leave through this separately approved read. Audit is
  /// durable before returning it; a lost response must never silently replay.
  Future<Map<String, Object?>> readCredentialReveal(
    String session,
    String requestId,
    String operationId,
  ) => _service.owner._serialize(() async {
    _useId(operationId, 'operationId');
    final r = _service._sessionUseRequest(session, requestId);
    if (!r.isReveal) throw const CredentialUseFailure('scope_not_approved');
    void validate() => _service._requireReusableUseGrant(
      _service._useRequest(requestId),
      session,
    );
    validate();
    if (_service._runtimeRepository.credentialUseRequests.any(
      (other) =>
          _service._credentialUseSessions[other.id] == session &&
          other.revealReads.any((read) => read.operationId == operationId),
    )) {
      throw const CredentialUseFailure(
        'attempt_consumed',
        attemptConsumed: true,
      );
    }
    if (r.revealReads.length >= 1000) {
      throw const CredentialUseFailure('limit_exceeded');
    }
    final c = _service._useEligible(r);
    if (c.form != CredentialForm.string) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final material = _service._currentCredentialMaterial(c);
    final read = CredentialRevealRead(operationId, _service._clock().toUtc());
    await _service._saveUse(
      request: r.changed({
        'revealReads': [...r.revealReads.map((v) => v.toJson()), read.toJson()],
      }),
      validate: validate,
    );
    validate();
    return {
      'protocolVersion': 2,
      'status': 'ok',
      'useKind': 'credential_reveal',
      'requestId': r.id,
      'operationId': operationId,
      'credentialId': c.id,
      'version': c.version,
      'secret': utf8.decode(material.bytes),
      'notice': '原文已交给 AI，将进入当前聊天上下文。',
    };
  });
}
