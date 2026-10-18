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
    final old = _service._runtimeRepository.credentialExecutions
        .where((e) => e.id == executionId)
        .firstOrNull;
    final registered = old?.materialLease;
    if (old == null ||
        old.state != 'preparing' ||
        registered == null ||
        registered.path != lease.path ||
        registered.identity != lease.identity ||
        lease.files.keys.toSet().difference({
          'credential.bin',
          'aws-config',
        }).isNotEmpty ||
        lease.files.length != 2) {
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
    if (record.materialLease == null || record.cleanupState == 'complete') {
      return record;
    }
    if (!{'exited', 'prepare_failed', 'start_failed'}.contains(record.state)) {
      await _saveUse(
        execution: record.changed({'cleanupState': 'needs_check'}),
      );
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
