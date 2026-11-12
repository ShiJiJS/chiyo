part of 'info_core.dart';

/// Private operation proof, never credential material or a reusable read grant.
/// Device paths/PIDs are not looked up in the server's kernel or filesystem.
final class _DeviceCredentialExecution {
  _DeviceCredentialExecution(
    this.deviceId,
    this.capability, {
    this.materialDigest,
    this.workerPid,
    this.workerIdentity,
    this.treeEnded = false,
  });
  final String deviceId, capability;
  final String? materialDigest, workerIdentity;
  final int? workerPid;
  final bool treeEnded;
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'capability': capability,
    'materialDigest': materialDigest,
    'workerPid': workerPid,
    'workerIdentity': workerIdentity,
    'treeEnded': treeEnded,
  };
  factory _DeviceCredentialExecution.fromJson(Map<String, dynamic> json) {
    if (json.length != 6 ||
        json['deviceId'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(json['deviceId'] as String) ||
        json['capability'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}=?$',
        ).hasMatch(json['capability'] as String) ||
        json['treeEnded'] is! bool ||
        (json['workerPid'] == null) != (json['workerIdentity'] == null) ||
        json['workerPid'] != null &&
            (json['workerPid'] is! int || (json['workerPid'] as int) < 1) ||
        json['workerIdentity'] != null &&
            (json['workerIdentity'] is! String ||
                (json['workerIdentity'] as String).isEmpty ||
                (json['workerIdentity'] as String).length > 2000) ||
        json['materialDigest'] != null &&
            (json['materialDigest'] is! String ||
                !RegExp(
                  r'^sha256:[0-9a-f]{64}$',
                ).hasMatch(json['materialDigest'] as String))) {
      throw const FormatException('Invalid private device execution');
    }
    return _DeviceCredentialExecution(
      json['deviceId'] as String,
      json['capability'] as String,
      materialDigest: json['materialDigest'] as String?,
      workerPid: json['workerPid'] as int?,
      workerIdentity: json['workerIdentity'] as String?,
      treeEnded: json['treeEnded'] as bool,
    );
  }
  _DeviceCredentialExecution changed(Map<String, Object?> values) =>
      _DeviceCredentialExecution.fromJson({...toJson(), ...values});
  static bool validJob(String value) => RegExp(
    r'^(?:macos:AgentInfoRuntime-|Local\\AgentInfoRuntime-)[A-Za-z0-9_-]{32}$',
  ).hasMatch(value);
}

extension DeviceCredentialExecutionAgentAccess on AgentAccess {
  CredentialExecution deviceCredentialExecutionStatus(
    String deviceId,
    String session,
    String id,
  ) {
    final record = credentialExecutionStatus(session, id);
    checkDeviceCredentialRequest(
      deviceId,
      session,
      record.requestId,
      allowEnded: true,
    );
    return record;
  }

  CredentialOperationClaim? deviceCredentialOperationStatus(
    String deviceId,
    String session,
    CredentialOperationInput input,
  ) {
    checkDeviceCredentialRequest(
      deviceId,
      session,
      input.requestId,
      allowEnded: true,
    );
    return credentialUseOperationStatus(session, input);
  }

  Future<CredentialOperationClaim> beginDeviceCredentialOperation(
    String deviceId,
    String session,
    CredentialOperationInput input,
    DeviceCredentialLaunch prepared,
    String jobName,
  ) => _service.owner._serialize(() async {
    final r = checkDeviceCredentialRequest(deviceId, session, input.requestId);
    final existing = deviceCredentialOperationStatus(deviceId, session, input);
    if (existing != null) {
      return existing; // Metadata only, never reissue bytes.
    }
    if (!_DeviceCredentialExecution.validJob(jobName)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    void validate() => _service._requireReusableUseGrant(r, session);
    validate();
    if (input.launch.receiver != r.plan.receiver) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    final resolved = prepared.resolve(input.launch);
    final credential = _service._useEligible(r);
    final delivery = _validateCredentialReceiver(
      CredentialUseInput._(
        r.purpose,
        r.alias,
        r.credentialId,
        r.version,
        input.launch,
        r.fields,
        2,
      ),
      credential,
    );
    final plan = delivery.resolved(resolved.executable, resolved.cwd);
    plan.requireApprovedProgramScope(r.plan);
    final now = DateTime.fromMillisecondsSinceEpoch(
      _service._clock().millisecondsSinceEpoch,
      isUtc: true,
    );
    final execution = CredentialExecution(
      id: _service._secret(),
      requestId: r.id,
      protocolVersion: 2,
      operationId: input.operationId,
      operationFingerprint: input.fingerprint,
      operationPlan: plan,
      createdAt: now,
      jobName: jobName,
      cleanupState: plan.requiresMaterialFiles ? 'pending' : 'not_needed',
    );
    validate();
    final value = _service._currentCredentialMaterial(credential);
    if (value.bytes.isEmpty) {
      throw const CredentialUseFailure('material_prepare_failed');
    }
    await _service._saveUse(
      request: r.changed({
        'executionId': execution.id,
        'attemptedAt': _useTimestamp(now),
      }),
      execution: execution,
      validate: validate,
    );
    final proof = _DeviceCredentialExecution(deviceId, _service._secret());
    _service._deviceCredentialExecutions[execution.id] = proof;
    _service._executionCapabilities[execution.id] = proof.capability;
    // The outer OnlineInformationRuntime checkpoints this proof before any
    // HTTPS response can publish material. No server plaintext file is created.
    final material = CredentialExecutionMaterial(
      execution.id,
      proof.capability,
      plan,
      CredentialMaterialValue(
        credential.id,
        credential.version,
        credential.form,
        value.bytes,
      ),
      r.alias,
      null,
      plan.receiver == 'ssh_identity'
          ? {'ssh_known_hosts': _service._sshHostTrust!.bytes}
          : const {},
      jobName,
    );
    return CredentialOperationClaim(
      execution,
      material: material,
      grantState: _service._useGrantState(r),
    );
  });

  (CredentialExecution, _DeviceCredentialExecution) _deviceExecution(
    String deviceId,
    String id,
    String capability,
  ) {
    final proof = _service._deviceCredentialExecutions[id];
    final record = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == id)
        .firstOrNull;
    if (proof == null ||
        record == null ||
        proof.deviceId != deviceId ||
        _service._deviceCredentialRequests[record.requestId] != deviceId ||
        proof.capability != capability ||
        _service._executionCapabilities[id] != capability) {
      throw const CredentialUseFailure('session_mismatch');
    }
    return (record, proof);
  }

  Future<void> registerDeviceCredentialMaterials(
    String deviceId,
    String id,
    String capability,
    CredentialMaterialLease lease,
  ) => _service.owner._serialize(() async {
    final (record, proof) = _deviceExecution(deviceId, id, capability);
    _service._requireSettledExecutionReceipt(id);
    final r = _service._useRequest(record.requestId);
    _service._requireReusableUseGrant(r, _service._credentialUseSessions[r.id]);
    final names = switch (record.operationPlan!.receiver) {
      'program_file' => {'credential.bin'},
      'aws_shared_credentials' => {'credential.bin', 'aws-config'},
      'ssh_identity' => {
        'credential.bin',
        'ssh-config',
        'known-hosts',
        'global-known-hosts',
      },
      _ => <String>{},
    };
    if (record.state != 'preparing' ||
        proof.treeEnded ||
        names.isEmpty ||
        lease.path.isEmpty ||
        lease.identity.isEmpty ||
        lease.files.length != names.length ||
        !lease.files.keys.toSet().containsAll(names) ||
        lease.files.values.any((v) => v.isEmpty)) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final digest = _useFingerprint(lease.toPrivateJson());
    if (proof.materialDigest != null && proof.materialDigest != digest) {
      throw const CredentialUseFailure('invalid_reference');
    }
    _service._deviceCredentialExecutions[id] = proof.changed({
      'materialDigest': digest,
    });
  });

  Future<void> registerDeviceCredentialWorker(
    String deviceId,
    String id,
    String capability,
    int workerPid,
    String identity,
  ) => _service.owner._serialize(() async {
    final (record, proof) = _deviceExecution(deviceId, id, capability);
    _service._requireSettledExecutionReceipt(id);
    final r = _service._useRequest(record.requestId);
    _service._requireReusableUseGrant(r, _service._credentialUseSessions[r.id]);
    if (record.state != 'preparing' ||
        proof.treeEnded ||
        workerPid < 1 ||
        identity.isEmpty ||
        identity.length > 2000 ||
        proof.workerPid != null &&
            (proof.workerPid != workerPid ||
                proof.workerIdentity != identity) ||
        record.operationPlan!.requiresMaterialFiles &&
            proof.materialDigest == null) {
      throw const CredentialUseFailure('invalid_plan');
    }
    _service._deviceCredentialExecutions[id] = proof.changed({
      'workerPid': workerPid,
      'workerIdentity': identity,
    });
  });

  Future<CredentialExecution> reportDeviceCredentialExecution(
    String deviceId,
    CredentialExecutionReport report,
  ) {
    final (_, proof) = _deviceExecution(
      deviceId,
      report.executionId,
      report.executionCapability,
    );
    if (report.state == 'running' && proof.workerPid == null) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return _reportCredentialExecution(report, verifyLocalProcess: false);
  }

  Future<CredentialExecution> acknowledgeDeviceCredentialCleanup(
    String deviceId,
    String id,
    String capability, {
    required bool treeEnded,
  }) => _service.owner._serialize(() async {
    final (record, proof) = _deviceExecution(deviceId, id, capability);
    _service._requireSettledExecutionReceipt(id);
    if (!treeEnded ||
        !{
          'exited',
          'prepare_failed',
          'start_failed',
          'unknown',
        }.contains(record.state)) {
      throw const CredentialUseFailure('cleanup_busy', attemptConsumed: true);
    }
    final changed = record.changed({
      'cleanupState': !record.operationPlan!.requiresMaterialFiles
          ? 'not_needed'
          : 'complete',
    });
    await _service._saveUse(execution: changed);
    _service._deviceCredentialExecutions[id] = proof.changed({
      'treeEnded': true,
    });
    return changed;
  });
}
