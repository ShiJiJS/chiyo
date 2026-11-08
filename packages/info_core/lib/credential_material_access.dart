part of 'info_core.dart';

extension CredentialMaterialAgentAccess on AgentAccess {
  Future<void> registerCredentialMaterials(
    String executionId,
    String capability,
    CredentialMaterialLease lease,
  ) => _service.owner._serialize(() async {
    if (_service._executionCapabilities[executionId] != capability) {
      throw const CredentialUseFailure('session_mismatch');
    }
    _service._requireSettledExecutionReceipt(executionId);
    final old = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == executionId)
        .firstOrNull;
    final registered = old?.materialLease;
    final receiver = old == null
        ? null
        : (old.operationPlan ?? _service._useRequest(old.requestId).plan)
              .receiver;
    final names = switch (receiver) {
      'aws_shared_credentials' => {'credential.bin', 'aws-config'},
      'ssh_identity' => {
        'credential.bin',
        'ssh-config',
        'known-hosts',
        'global-known-hosts',
      },
      _ => <String>{},
    };
    if (old == null ||
        old.state != 'preparing' ||
        registered == null ||
        registered.path != lease.path ||
        registered.identity != lease.identity ||
        names.isEmpty ||
        lease.files.keys.toSet().difference(names).isNotEmpty ||
        lease.files.length != names.length) {
      throw const CredentialUseFailure('invalid_reference');
    }
    if (registered.files.isNotEmpty &&
        jsonEncode(registered.files) != jsonEncode(lease.files)) {
      throw const CredentialUseFailure('invalid_reference');
    }
    try {
      ManagedCredentialFiles.verify(lease);
    } on Object {
      throw const CredentialUseFailure('material_prepare_failed');
    }
    await _service._saveUse(
      execution: old.changed({'materialLease': lease.toPrivateJson()}),
    );
  });
  Future<CredentialExecution> cleanupCredentialExecution(
    String session,
    String executionId,
  ) => _service.owner._serialize(() async {
    final record = credentialExecutionStatus(session, executionId);
    return _service._cleanupMaterialExecution(record);
  });
}

extension _CredentialMaterialService on InformationService {
  Future<CredentialExecution> _cleanupMaterialExecution(
    CredentialExecution record,
  ) async {
    _requireSettledExecutionReceipt(record.id);
    if (_deviceCredentialRequests.containsKey(record.requestId)) {
      if ({'not_needed', 'complete'}.contains(record.cleanupState)) {
        return record;
      }
      throw const CredentialUseFailure('cleanup_busy', attemptConsumed: true);
    }
    if (record.materialLease == null || record.cleanupState == 'complete') {
      return record;
    }
    final unknownTreeEnded =
        record.state == 'unknown' &&
        record.jobName != null &&
        CredentialProcessJob.isActive(
              record.jobName!,
              workerPid: record.workerPid,
              workerCreatedAt: record.workerCreatedAt,
            ) ==
            false;
    final registeredTreeMayBeActive =
        record.jobName != null &&
        CredentialProcessJob.isActive(
              record.jobName!,
              workerPid: record.workerPid,
              workerCreatedAt: record.workerCreatedAt,
            ) !=
            false;
    if (registeredTreeMayBeActive ||
        (!{'exited', 'prepare_failed', 'start_failed'}.contains(record.state) &&
            !unknownTreeEnded)) {
      if (record.cleanupState != 'needs_check') {
        await _saveUse(
          execution: record.changed({'cleanupState': 'needs_check'}),
        );
      }
      throw const CredentialUseFailure('cleanup_busy', attemptConsumed: true);
    }
    String? code;
    var state = 'complete';
    try {
      ManagedCredentialFiles.cleanup(record.materialLease!);
    } on RuntimeMaterialFailure catch (e) {
      state = e.code == 'cleanup_failed' ? 'failed' : 'needs_check';
      code = e.code == 'cleanup_failed'
          ? 'cleanup_failed'
          : 'cleanup_identity_mismatch';
    } on Object {
      state = 'failed';
      code = 'cleanup_failed';
    }
    final updated = record.changed({'cleanupState': state});
    await _saveUse(execution: updated);
    if (code != null) {
      throw CredentialUseFailure(
        code,
        attemptConsumed: true,
        executionId: record.id,
      );
    }
    return updated;
  }
}

extension CredentialMaterialOwnerAccess on OwnerAccess {
  List<CredentialExecution> get credentialMaterialChecks => List.unmodifiable(
    _service._runtimeRepository.credentialExecutions.where(
      (e) =>
          !_service._pendingExecutionReceipts.containsKey(e.id) &&
          e.materialLease != null &&
          e.cleanupState != 'complete' &&
          !{'preparing', 'running'}.contains(e.state),
    ),
  );
  Future<int> reconcileCredentialMaterialCleanup() => _serialize(() async {
    // An empty job before launch is not proof of completion while its original
    // supervisor can still start the worker. Preserve that launch/report path.
    for (final record
        in _service._runtimeRepository.credentialExecutions.toList()) {
      if (_service._deviceCredentialRequests.containsKey(record.requestId)) {
        continue;
      }
      if (_service._pendingExecutionReceipts.containsKey(record.id)) continue;
      if ({'preparing', 'running'}.contains(record.state) &&
          record.supervisorPid != null &&
          record.supervisorCreatedAt != null &&
          CredentialProcessIdentity.isActive(
                record.supervisorPid!,
                record.supervisorCreatedAt!,
              ) ==
              false) {
        await _service._saveUse(
          execution: record.changed({
            'executionState': 'unknown',
            'errorCode': 'execution_unknown',
          }),
        );
      }
    }
    for (final record in credentialMaterialChecks) {
      try {
        await _service._cleanupMaterialExecution(record);
      } on CredentialUseFailure catch (e) {
        if (!{
          'cleanup_busy',
          'cleanup_identity_mismatch',
          'cleanup_failed',
        }.contains(e.code)) {
          rethrow;
        }
      }
    }
    return credentialMaterialChecks.length;
  });
  Future<CredentialExecution> cleanupCredentialExecution(String executionId) =>
      _serialize(() async {
        final record = _service._runtimeRepository.credentialExecutions
            .where((e) => e.id == executionId)
            .firstOrNull;
        if (record == null) {
          throw const CredentialUseFailure('invalid_reference');
        }
        return _service._cleanupMaterialExecution(record);
      });
}
