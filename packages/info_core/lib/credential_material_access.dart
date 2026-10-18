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
    final receiver = old == null
        ? null
        : _service._useRequest(old.requestId).plan.receiver;
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
    if (record.materialLease == null || record.cleanupState == 'complete') {
      return record;
    }
    final unknownTreeEnded =
        record.state == 'unknown' &&
        record.jobName != null &&
        CredentialProcessJob.isActive(record.jobName!) == false;
    if (!{'exited', 'prepare_failed', 'start_failed'}.contains(record.state) &&
        !unknownTreeEnded) {
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
