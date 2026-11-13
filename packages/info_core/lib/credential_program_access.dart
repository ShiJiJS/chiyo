part of 'info_core.dart';

extension _CredentialPrograms on InformationService {
  CredentialProgramRepository get _programRepository {
    if (_closed || _backupBusy || _repository is! CredentialProgramRepository) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    return _repository as CredentialProgramRepository;
  }

  CredentialProgramOperation _programOperation(String id) =>
      _programRepository.credentialProgramOperations
          .where((o) => o.id == id)
          .firstOrNull ??
      (throw const CredentialUseFailure('session_mismatch'));
  Future<void> _saveProgram(
    CredentialProgramOperation next,
    int revision, {
    void Function()? validate,
  }) => _programRepository.commitCredentialProgramOperation(
    next,
    expectedRevision: revision,
    requestRevision: _batchRequest(next.requestId).revision,
    validate: validate ?? () {},
  );
  Map<String, Object?> _programView(CredentialProgramOperation operation) => {
    ...operation.toPublicJson(),
    'observedAt': _useTimestamp(_clock()),
    if (operation.progress.state == 'preparing' &&
        !_clock().isBefore(
          operation.progress.createdAt!.add(const Duration(seconds: 30)),
        )) ...{
      'executionState': 'unknown',
      'errorCode': 'execution_unknown',
    },
  };
  (CredentialProgramOperation, _DeviceCredentialExecution) _programProof(
    String device,
    String id,
    String capability,
  ) {
    final operation = _programOperation(id),
        proof = _credentialProgramProofs[id];
    if (operation.archived ||
        proof == null ||
        proof.deviceId != device ||
        operation.deviceId != device ||
        proof.capability != capability ||
        _batchRequest(operation.requestId).archived) {
      throw const CredentialUseFailure('session_mismatch');
    }
    return (operation, proof);
  }

  void _requireProgramStart(
    CredentialProgramOperation operation,
    _DeviceCredentialExecution proof,
  ) {
    if (operation.progress.state != 'preparing' ||
        proof.treeEnded ||
        !_clock().isBefore(
          operation.progress.createdAt!.add(const Duration(seconds: 30)),
        )) {
      throw const CredentialUseFailure('execution_unknown');
    }
    final request = _batchRequest(operation.requestId);
    for (final id in operation.itemIds) {
      _requireBatchItem(request, request.items.firstWhere((i) => i.id == id));
    }
  }

  Set<String> _programFiles(CredentialProgramOperation operation) => {
    for (var i = 0; i < operation.itemIds.length; i++)
      if (operation.plan.bindings[i].via == 'file')
        'credential-${operation.itemIds[i]}.bin',
  };
}

extension CredentialProgramAgentAccess on AgentAccess {
  bool get credentialProgramsAvailable =>
      !_service._closed &&
      !_service._backupBusy &&
      _service._repository is CredentialProgramRepository &&
      _service._repository is CredentialBatchRepository;

  CredentialProgramOperation credentialProgramOperation(
    String session,
    String deviceId,
    String operationId,
  ) {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session];
    final operation = _service._programRepository.credentialProgramOperations
        .where(
          (o) =>
              o.operationId == operationId &&
              o.sessionBinding == binding &&
              o.deviceId == deviceId &&
              !o.archived,
        )
        .firstOrNull;
    if (operation == null) {
      throw const CredentialUseFailure('invalid_reference');
    }
    _service._sessionBatch(session, deviceId, operation.requestId);
    return operation;
  }

  Map<String, Object?> credentialProgramOperationStatus(
    String session,
    String deviceId,
    String operationId,
  ) => _service._programView(
    credentialProgramOperation(session, deviceId, operationId),
  );

  Future<CredentialProgramClaim> beginCredentialProgramOperation(
    String session,
    String deviceId,
    String requestId,
    CredentialProgramPlan launch,
    DeviceCredentialLaunch prepared,
    String jobName, {
    required String operationId,
  }) => _service.owner._serialize(() async {
    _batchOperationId(operationId);
    final request = _service._sessionBatch(session, deviceId, requestId);
    if (request.programPlan == null ||
        !_DeviceCredentialExecution.validJob(jobName)) {
      throw const CredentialUseFailure('unsupported_receiver');
    }
    final resolved = prepared.resolveProgram(launch).withVersions({
      for (final i in request.items) i.credentialId: i.version,
    });
    final fingerprint = _useFingerprint({
      'requestId': requestId,
      'launch': resolved.toJson(),
      'jobName': jobName,
    });
    final previous = _service._programRepository.credentialProgramOperations
        .where(
          (o) =>
              o.sessionBinding == request.sessionBinding &&
              o.operationId == operationId,
        )
        .firstOrNull;
    if (previous != null) {
      if (previous.archived ||
          previous.deviceId != deviceId ||
          previous.fingerprint != fingerprint) {
        throw const CredentialUseFailure('operation_conflict');
      }
      return CredentialProgramClaim(previous);
    }
    if (_service._programRepository.credentialProgramOperations.any(
          (o) => o.deviceId == deviceId && o.progress.jobName == jobName,
        ) ||
        _service._repository is CredentialRuntimeRepository &&
            _service._runtimeRepository.credentialExecutions.any(
              (e) =>
                  e.jobName == jobName &&
                  _service._deviceCredentialRequests[e.requestId] == deviceId,
            )) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (!_reserveAgentOperation(
      session,
      operationId,
      'credential-program',
      fingerprint,
    )) {
      throw const CredentialUseFailure('operation_conflict');
    }
    resolved.requireApprovedScope(request.programPlan!);
    final selected = <CredentialBatchItem>[];
    for (final binding in resolved.bindings) {
      final item = request.items
          .where(
            (i) =>
                i.destination.program?.binding.fingerprint ==
                binding.fingerprint,
          )
          .firstOrNull;
      if (item == null) throw const CredentialUseFailure('scope_not_approved');
      selected.add(item);
    }
    void guard() {
      final current = _service._sessionBatch(session, deviceId, requestId);
      for (final item in selected) {
        _service._requireBatchItem(current, item);
      }
    }

    guard();
    // Prepare all required material before reserving the original launch. A
    // failed B cannot leave a started process that only received A.
    final materials = <String, CredentialMaterialValue>{};
    final values = <String, CredentialMaterialValue>{};
    for (final (index, item) in selected.indexed) {
      final credential = _service._guardUseEligibility(
        item.credentialId,
        item.version,
        generation: item.useGeneration,
      );
      if (!resolved.bindings[index].acceptsForm(credential.form)) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      final key = jsonEncode([credential.id, credential.version]);
      final material = values.putIfAbsent(
        key,
        () => CredentialMaterialValue(
          credential.id,
          credential.version,
          credential.form,
          _service._currentCredentialMaterial(credential).bytes,
        ),
      );
      if (material.bytes.isEmpty) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      if (resolved.bindings[index].via == 'env' &&
          material.stringValue.contains('\x00')) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      materials[item.id] = material;
    }
    final now = _batchTime(_service._clock()),
        id = _service._secret(),
        capability = _service._secret();
    final operation = CredentialProgramOperation(
      sessionBinding: request.sessionBinding,
      deviceId: deviceId,
      plan: resolved,
      itemIds: selected.map((i) => i.id),
      progress: CredentialExecution(
        id: id,
        requestId: requestId,
        protocolVersion: 2,
        operationId: operationId,
        operationFingerprint: fingerprint,
        createdAt: now,
        jobName: jobName,
        cleanupState: resolved.bindings.any((b) => b.via == 'file')
            ? 'pending'
            : 'not_needed',
      ),
    );
    await _service._saveProgram(operation, 0, validate: guard);
    _service._credentialProgramProofs[id] = _DeviceCredentialExecution(
      deviceId,
      capability,
    );
    return CredentialProgramClaim(
      operation,
      material: CredentialProgramMaterial(
        executionId: id,
        requestId: requestId,
        operationId: operationId,
        executionCapability: capability,
        jobName: jobName,
        plan: resolved,
        itemIds: selected.map((i) => i.id),
        materials: materials,
      ),
    );
  });

  void authorizeCredentialProgramStart(
    String deviceId,
    String id,
    String capability,
  ) {
    final (operation, proof) = _service._programProof(deviceId, id, capability);
    _service._requireProgramStart(operation, proof);
  }

  Future<void> registerCredentialProgramMaterials(
    String deviceId,
    String id,
    String capability,
    CredentialMaterialLease lease,
  ) => _service.owner._serialize(() async {
    final (operation, proof) = _service._programProof(deviceId, id, capability);
    _service._requireProgramStart(operation, proof);
    final names = _service._programFiles(operation),
        digest = _useFingerprint(lease.toPrivateJson()),
        previous = operation.progress.materialLease;
    if (names.isEmpty ||
        lease.path.isEmpty ||
        lease.identity.isEmpty ||
        lease.files.length != names.length ||
        !lease.files.keys.toSet().containsAll(names) ||
        lease.files.values.any((v) => v.isEmpty) ||
        previous != null &&
            _useFingerprint(previous.toPrivateJson()) != digest) {
      throw const CredentialUseFailure('invalid_reference');
    }
    if (previous != null) return;
    final next = operation.withProgress(
      operation.progress.changed({'materialLease': lease.toPrivateJson()}),
    );
    await _service._saveProgram(
      next,
      operation.revision,
      validate: () => _service._requireProgramStart(operation, proof),
    );
  });

  Future<void> registerCredentialProgramWorker(
    String deviceId,
    String id,
    String capability,
    int workerPid,
    String identity,
  ) => _service.owner._serialize(() async {
    final (operation, proof) = _service._programProof(deviceId, id, capability);
    _service._requireProgramStart(operation, proof);
    if (workerPid < 1 ||
        identity.isEmpty ||
        identity.length > 2000 ||
        identity.contains('\x00') ||
        _service._programFiles(operation).isNotEmpty &&
            operation.progress.materialLease == null ||
        operation.progress.workerPid != null &&
            (operation.progress.workerPid != workerPid ||
                operation.progress.workerCreatedAt != identity)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (operation.progress.workerPid == workerPid) return;
    final next = operation.withProgress(
      operation.progress.changed({
        'workerPid': workerPid,
        'workerCreatedAt': identity,
      }),
    );
    await _service._saveProgram(
      next,
      operation.revision,
      validate: () => _service._requireProgramStart(operation, proof),
    );
  });

  Future<CredentialProgramOperation> reportCredentialProgramExecution(
    String deviceId,
    CredentialExecutionReport report,
  ) => _service.owner._serialize(() async {
    final (operation, proof) = _service._programProof(
      deviceId,
      report.executionId,
      report.executionCapability,
    );
    if (report.state == 'running' &&
        (operation.progress.workerPid == null || proof.treeEnded)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final next = operation.withReport(report);
    if (identical(next, operation)) return operation;
    await _service._saveProgram(next, operation.revision);
    return next;
  });

  Future<CredentialProgramOperation> acknowledgeCredentialProgramCleanup(
    String deviceId,
    String id,
    String capability, {
    required bool treeEnded,
  }) => _service.owner._serialize(() async {
    final (operation, proof) = _service._programProof(deviceId, id, capability);
    if (!treeEnded ||
        !{
          'exited',
          'prepare_failed',
          'start_failed',
          'unknown',
        }.contains(operation.progress.state)) {
      throw const CredentialUseFailure('cleanup_busy');
    }
    if (proof.treeEnded) return operation;
    final next = operation.withProgress(
      operation.progress.changed({
        'cleanupState': _service._programFiles(operation).isEmpty
            ? 'not_needed'
            : 'complete',
      }),
    );
    await _service._saveProgram(next, operation.revision);
    _service._credentialProgramProofs[id] = proof.changed({'treeEnded': true});
    return next;
  });
}

extension CredentialProgramOwnerAccess on OwnerAccess {
  List<CredentialProgramOperation> get credentialProgramOperations =>
      _service._programRepository.credentialProgramOperations;
  Map<String, Object?> credentialProgramOperationView(
    CredentialProgramOperation operation,
  ) => _service._programView(operation);

  /// A device report, never an inspection of a foreign PID or path by Owner.
  /// Root-process exit alone does not prove its workers/descendants ended.
  bool credentialProgramProcessUnconfirmed(CredentialProgramOperation record) {
    final current = _service._programOperation(record.id);
    if (current.archived ||
        _service._credentialProgramProofs[current.id]?.treeEnded == true) {
      return false;
    }
    final p = current.progress;
    return {'preparing', 'running', 'unknown'}.contains(p.state) ||
        p.processStarted ||
        p.workerPid != null;
  }
}

extension _ProgramRuntimeMaintenance on OnlineInformationRuntime {
  Future<void> _maintainCredentialPrograms() async {
    if (service._repository is! CredentialProgramRepository) return;
    for (final operation
        in service._programRepository.credentialProgramOperations) {
      if (operation.archived ||
          !{'preparing', 'running'}.contains(operation.progress.state)) {
        continue;
      }
      final proof = service._credentialProgramProofs[operation.id];
      if (operation.progress.state == 'running' && proof == null) {
        throw const FormatException('Missing program execution proof');
      }
      if (operation.progress.state == 'preparing' &&
          (proof == null ||
              operation.progress.workerPid == null &&
                  !service._clock().isBefore(
                    operation.progress.createdAt!.add(
                      const Duration(seconds: 30),
                    ),
                  ))) {
        await service.owner._serialize(
          () => service._saveProgram(
            operation.withProgress(
              operation.progress.changed({
                'executionState': 'unknown',
                'errorCode': 'execution_unknown',
              }),
            ),
            operation.revision,
          ),
        );
      }
    }
  }

  Map<String, Object?> _encodeCredentialPrograms() => {
    for (final entry in service._credentialProgramProofs.entries)
      entry.key: entry.value.toJson(),
  };
  void _restoreCredentialPrograms(Object? value) {
    if (value is! Map ||
        value.length > 100000 ||
        service._repository is! CredentialProgramRepository) {
      throw const FormatException('Invalid program execution state');
    }
    final proofs = {
      for (final p in service._deviceCredentialExecutions.values) p.capability,
    };
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid program execution proof');
      }
      final proof = _DeviceCredentialExecution.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      final operation = service._programOperation(entry.key as String),
          progress = operation.progress;
      final request = service._batchRequest(operation.requestId);
      if (operation.archived ||
          request.archived ||
          operation.deviceId != proof.deviceId ||
          !service._sessionBindings.values.contains(operation.sessionBinding) ||
          !proofs.add(proof.capability) ||
          // Program registrations live in the operation row. The private
          // checkpoint holds control only, not a second mutable registry.
          proof.workerPid != null ||
          proof.workerIdentity != null ||
          proof.materialDigest != null ||
          proof.treeEnded &&
              (!{
                    'exited',
                    'prepare_failed',
                    'start_failed',
                    'unknown',
                  }.contains(progress.state) ||
                  !{
                    'complete',
                    'not_needed',
                  }.contains(progress.cleanupState))) {
        throw const FormatException('Inconsistent program execution proof');
      }
      service._credentialProgramProofs[operation.id] = proof;
    }
  }
}
