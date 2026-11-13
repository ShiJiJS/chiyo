import 'package:info_core/info_core.dart' as core;
import 'owner_credential_use_projection.dart';
import 'owner_workspace_credential_batches.dart';
import 'workspace_source.dart';

/// Original Owner projections only. No process inspection, path traversal,
/// credential acquisition, material cleanup or execution happens here.
class OwnerRuntimeMaterials {
  OwnerRuntimeMaterials(this.owner)
    : _credentials = OwnerCredentialUseProjection(owner);
  final core.OwnerAccess owner;
  final OwnerCredentialUseProjection _credentials;
  List<WorkspaceApprovalExecution> materials() => [
    for (final e in owner.credentialExecutions.where(
      (e) => e.restoredAt == null,
    ))
      for (final r in owner.credentialUseRequests.where(
        (r) => r.isCommand && r.restoredAt == null && r.id == e.requestId,
      ))
        if (r.plan.requiresMaterialFiles) _credentials.execution(r, e),
  ];
  List<WorkspaceRuntimeProgram> programs() {
    final projection = OwnerWorkspaceCredentialBatches(owner);
    return [
          for (final o in owner.credentialProgramOperations.where(
            (o) => !o.archived,
          ))
            WorkspaceRuntimeProgram(
              projection.programOperationView(o),
              processUnconfirmed: owner.credentialProgramProcessUnconfirmed(o),
            ),
        ]
        .where(
          (p) =>
              p.processUnconfirmed ||
              p.operation.state == 'unknown' ||
              p.holdsMaterial,
        )
        .toList();
  }

  int unconfirmedProcesses(List<WorkspaceRuntimeProgram> programs) =>
      owner.credentialExecutions
          .where(
            (e) =>
                e.restoredAt == null &&
                {'preparing', 'running', 'unknown'}.contains(e.state),
          )
          .length +
      programs.where((p) => p.processUnconfirmed).length;
  List<WorkspaceCopyMaintenance> copies() => [
    for (final d in owner.informationFileDeliveries)
      if (d.runtime && d.restoredAt == null)
        WorkspaceCopyMaintenance(
          id: d.id,
          requestId: d.requestId,
          record: WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            d.field.itemId,
          ),
          name: d.fileName,
          fileVersion: d.attachment.attachmentVersion,
          expiresAt: d.expiresAt,
          state: !d.holdsCopy
              ? WorkspaceCopyState.released
              : d.state == 'ready'
              ? WorkspaceCopyState.active
              : WorkspaceCopyState.pending,
          reason: d.cleanupError == null ? null : '登记路径尚未安全移除，请重新核对。',
        ),
  ];
}
