import 'package:info_core/info_core.dart' as core;
import 'owner_credential_use_projection.dart';
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
        (r) => !r.isFocusedFill && r.restoredAt == null && r.id == e.requestId,
      ))
        if (r.plan.receiver != 'gh_token') _credentials.execution(r, e),
  ];
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
