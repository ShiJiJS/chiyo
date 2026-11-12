part of 'info_core.dart';

/// A short lived operation proof, separate from the chat and credential grant.
/// Only the App's private device transport uses it. It never appears in audit
/// projections, portable backups, CLI output or native-driver diagnostics.
final class _DeviceFocusedFill {
  const _DeviceFocusedFill(
    this.deviceId,
    this.capability,
    this.deadline, {
    this.materialClaimed = false,
  });
  final String deviceId, capability;
  final DateTime deadline;
  final bool materialClaimed;
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'capability': capability,
    'deadline': _useTimestamp(deadline),
    'materialClaimed': materialClaimed,
  };
  factory _DeviceFocusedFill.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'deviceId', 'capability', 'deadline', 'materialClaimed'});
    if (!RegExp(
          r'^[A-Za-z0-9_-]{22}$',
        ).hasMatch(json['deviceId'] as String? ?? '') ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}=?$',
        ).hasMatch(json['capability'] as String? ?? '') ||
        json['materialClaimed'] is! bool) {
      throw const FormatException('Invalid device fill');
    }
    return _DeviceFocusedFill(
      json['deviceId'] as String,
      json['capability'] as String,
      DateTime.parse(json['deadline'] as String).toUtc(),
      materialClaimed: json['materialClaimed'] as bool,
    );
  }
}

extension DeviceFocusedFillAgentAccess on AgentAccess {
  bool get deviceFocusedFillAvailable =>
      _service._deviceFileDelivery &&
      _service._repository is FocusedFillRuntimeRepository &&
      !_service._closed;

  /// The App has inspected its own application; the NAS validates the portable
  /// identity shape without probing a foreign path in its kernel/filesystem.
  Future<CredentialUseRequest> requestDeviceFocusedFill(
    String deviceId,
    String session,
    FocusedFillInput input,
  ) async {
    if (!deviceFocusedFillAvailable) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(deviceId)) {
      throw const CredentialUseFailure('session_mismatch');
    }
    final request = await _requestFocusedFill(
      session,
      input,
      inspector: (application) async => application,
      available: true,
    );
    _service._deviceCredentialRequests[request.id] = deviceId;
    return request;
  }

  Map<String, Object?> deviceFocusedFillStatus(
    String deviceId,
    String session,
    FocusedFillOperationInput input,
  ) {
    checkDeviceCredentialRequest(
      deviceId,
      session,
      input.requestId,
      allowEnded: true,
    );
    return focusedFillStatus(session, input);
  }

  Future<Map<String, Object?>> beginDeviceFocusedFill(
    String deviceId,
    String session,
    FocusedFillOperationInput input,
  ) async {
    checkDeviceCredentialRequest(deviceId, session, input.requestId);
    final claim = await _claimFocusedFill(
      session,
      input,
      available: deviceFocusedFillAvailable,
    );
    if (!claim.$2) return _service._publicFill(claim.$1, duplicate: true);
    final proof = _DeviceFocusedFill(
      deviceId,
      _service._secret(),
      claim.$1.createdAt.add(const Duration(seconds: 30)),
    );
    _service._deviceFocusedFills[claim.$1.id] = proof;
    // OnlineInformationRuntime checkpoints the private proof before publishing.
    return {
      ..._service._publicFill(claim.$1),
      'fillCapability': proof.capability,
    };
  }

  (FocusedFillOperation, _DeviceFocusedFill, String) _deviceFill(
    String deviceId,
    String id,
    String capability, {
    bool requireActive = true,
  }) {
    final proof = _service._deviceFocusedFills[id];
    final record = _service._fillOperation(id);
    final session = _service._credentialUseSessions[record.requestId];
    if (proof == null ||
        proof.deviceId != deviceId ||
        proof.capability != capability ||
        _service._deviceCredentialRequests[record.requestId] != deviceId ||
        session == null) {
      throw const CredentialUseFailure('session_mismatch');
    }
    if (requireActive &&
        (record.state != FocusedFillState.checking ||
            !_service._clock().isBefore(proof.deadline))) {
      throw const CredentialUseFailure('fill_unknown', attemptConsumed: true);
    }
    return (record, proof, session);
  }

  Future<Map<String, Object?>> claimDeviceFocusedFillMaterial(
    String deviceId,
    String id,
    String capability,
    FocusedFillApplication application,
  ) => _service.owner._serialize(() async {
    final (record, proof, session) = _deviceFill(deviceId, id, capability);
    if (proof.materialClaimed) {
      throw const CredentialUseFailure('fill_unknown', attemptConsumed: true);
    }
    if (!record.application.matches(application)) {
      throw const CredentialUseFailure('application_changed');
    }
    final request = _service._requireFillGrant(session, record.requestId);
    await _service._saveFocusedFill(
      operation: record.changed({
        'checkedAt': _useTimestamp(_service._clock().toUtc()),
      }),
      validate: () => _service._requireFillGrant(session, record.requestId),
    );
    final material = _service._currentCredentialMaterial(
      _service._useEligible(request),
    );
    if (material.bytes.isEmpty) {
      throw const CredentialUseFailure('material_prepare_failed');
    }
    _service._deviceFocusedFills[id] = _DeviceFocusedFill(
      proof.deviceId,
      proof.capability,
      proof.deadline,
      materialClaimed: true,
    );
    return {
      'protocolVersion': 2,
      'status': 'ok',
      'materialBase64': base64Encode(material.bytes),
    };
  });

  Future<void> authorizeDeviceFocusedFillBatch(
    String deviceId,
    String id,
    String capability,
  ) => _service.owner._serialize(() async {
    final (record, proof, session) = _deviceFill(deviceId, id, capability);
    if (!proof.materialClaimed || record.checkedAt == null) {
      throw const CredentialUseFailure('invalid_reference');
    }
    _service._requireFillGrant(session, record.requestId);
    if (!record.inputReleased) {
      await _service._saveFocusedFill(
        operation: record.changed({'inputReleased': true}),
        validate: () => _service._requireFillGrant(session, record.requestId),
      );
    }
  });

  Future<Map<String, Object?>> finishDeviceFocusedFill(
    String deviceId,
    String id,
    String capability,
    FocusedFillBatchResult result,
  ) => _service.owner._serialize(() async {
    final (record, _, _) = _deviceFill(
      deviceId,
      id,
      capability,
      requireActive: false,
    );
    if (result.state == FocusedFillState.checking ||
        result.state == FocusedFillState.sent && result.errorCode != null ||
        result.state != FocusedFillState.sent &&
            !focusedFillErrorCodes.contains(result.errorCode) ||
        {
              FocusedFillState.sent,
              FocusedFillState.partial,
            }.contains(result.state) &&
            !record.inputReleased) {
      throw const CredentialUseFailure('invalid_type');
    }
    if (record.state != FocusedFillState.checking) {
      // A timed-out or recovered operation must never be revived by a late App.
      return _service._publicFill(record, duplicate: true);
    }
    final changed = record.changed({
      'fillState': result.state.name,
      'errorCode': result.errorCode,
      'finishedAt': _useTimestamp(_service._clock().toUtc()),
    });
    await _service._saveFocusedFill(operation: changed);
    return _service._publicFill(changed);
  });
}
