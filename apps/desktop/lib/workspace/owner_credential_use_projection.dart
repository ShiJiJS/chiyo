import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import 'workspace_source.dart';

/// Metadata only: never reads credential material or launch capabilities.
class OwnerCredentialUseProjection {
  OwnerCredentialUseProjection(this.owner);
  final core.OwnerAccess owner;
  final _observations = <String, (String, int)>{};
  WorkspaceCredentialRequestState state(core.CredentialUseRequest r) {
    if (owner.credentialUseDecisionUnconfirmed(r)) {
      return WorkspaceCredentialRequestState.unavailable;
    }
    final status = owner.credentialUseState(r);
    if (status == 'pending') return WorkspaceCredentialRequestState.pending;
    if (status == 'denied') return WorkspaceCredentialRequestState.denied;
    if (r.invalidatedCode == 'grant_revoked') {
      return WorkspaceCredentialRequestState.revoked;
    }
    return switch (owner.credentialGrantState(r)) {
      'available' || 'consumed' => WorkspaceCredentialRequestState.approved,
      'expired' => WorkspaceCredentialRequestState.expired,
      'version_invalidated' => WorkspaceCredentialRequestState.superseded,
      _ =>
        r.credentialApproved
            ? WorkspaceCredentialRequestState.revoked
            : r.approvedFields.isNotEmpty
            ? owner.credentialFieldGrantState(r) == 'available'
                  ? WorkspaceCredentialRequestState.partiallyApproved
                  : owner.credentialFieldGrantState(r) == 'expired'
                  ? WorkspaceCredentialRequestState.expired
                  : WorkspaceCredentialRequestState.sessionEnded
            : status == 'expired'
            ? WorkspaceCredentialRequestState.expired
            : WorkspaceCredentialRequestState.sessionEnded,
    };
  }

  WorkspaceCredentialReceiver receiver(core.CredentialLaunchPlan p) =>
      WorkspaceCredentialReceiver(
        id: p.receiver,
        label: switch (p.receiver) {
          'gh_token' => 'GitHub CLI',
          'aws_shared_credentials' => 'AWS CLI',
          'ssh_identity' => 'OpenSSH',
          _ => '接收程序',
        },
        executable: p.path,
        workingDirectory: p.cwd,
        arguments: p.argv.map(
          (v) => switch (v.kind) {
            core.LaunchValueKind.literal => v.value,
            core.LaunchValueKind.file => '〈已批准普通文件〉',
            _ => '〈托管材料〉',
          },
        ),
        binding: p.env.keys.join('、'),
      );
  WorkspaceCredentialUseRequest request(core.CredentialUseRequest r) {
    final c = owner.credentials
        .where((c) => c.id == r.credentialId)
        .firstOrNull;
    final session = owner.credentialRequestSessionId(r.id);
    return WorkspaceCredentialUseRequest(
      id: r.id,
      ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, r.credentialId),
      credentialName: r.credentialName ?? c?.name ?? '原凭据已不可用',
      materialVersion: r.version,
      useGeneration: r.useGeneration,
      delivery: r.isFocusedFill
          ? WorkspaceCredentialDelivery.focus
          : r.plan.receiver == 'gh_token'
          ? WorkspaceCredentialDelivery.environment
          : WorkspaceCredentialDelivery.file,
      receiver: r.isFocusedFill
          ? WorkspaceCredentialReceiver(
              id: 'focused_fill',
              label: '本机焦点填充',
              executable: r.focusedFill!.application.executable,
              workingDirectory: '',
              arguments: [r.focusedFill!.targetHint],
              binding: '已指定应用与焦点目标',
            )
          : receiver(r.plan),
      session: WorkspaceCredentialSession(
        session ?? 'unlinked:${r.id}',
        session == null ? '${r.chatLabel}（历史会话身份不可用）' : r.chatLabel,
        '未提供 Agent 名称',
      ),
      purpose: r.purpose,
      minutes: r.credentialExpiresAt != null && r.decidedAt != null
          ? r.credentialExpiresAt!.difference(r.decidedAt!).inMinutes
          : 15,
      submittedAt: r.createdAt,
      state: state(r),
      approvalReference: r.id,
      requestExpiresAt: r.requestExpiresAt,
    );
  }

  WorkspaceApprovalExecution execution(
    core.CredentialUseRequest r,
    core.CredentialExecution e,
  ) {
    final signature = jsonEncode([
      e.state,
      e.processStarted,
      e.exitCode,
      e.errorCode,
      e.cleanupState,
      e.finishedAt?.toIso8601String(),
      e.restoredAt?.toIso8601String(),
    ]);
    final previous = _observations[e.id];
    final revision = previous == null
        ? 1
        : previous.$1 == signature
        ? previous.$2
        : previous.$2 + 1;
    _observations[e.id] = (signature, revision);
    return WorkspaceApprovalExecution(
      requestId: r.id,
      grantId: r.id,
      operationId: e.operationId ?? e.id,
      credential: request(r),
      plan: receiver(e.operationPlan ?? r.plan),
      createdAt: e.createdAt ?? r.createdAt,
      state: switch (e.state) {
        'preparing' => WorkspaceExecutionState.preparing,
        'running' => WorkspaceExecutionState.running,
        'exited' => WorkspaceExecutionState.exited,
        'prepare_failed' => WorkspaceExecutionState.prepareFailed,
        'start_failed' => WorkspaceExecutionState.startFailed,
        _ => WorkspaceExecutionState.unknown,
      },
      revision: revision,
      processStarted: e.processStarted,
      processEnded: {
        'exited',
        'prepare_failed',
        'start_failed',
      }.contains(e.state),
      cleanup: switch (e.cleanupState) {
        'complete' => WorkspaceExecutionCleanup.complete,
        'not_needed' => WorkspaceExecutionCleanup.notNeeded,
        'failed' => WorkspaceExecutionCleanup.failed,
        _ => WorkspaceExecutionCleanup.needsCheck,
      },
      exitCode: e.exitCode,
      errorCode: e.errorCode,
      observedAt: e.finishedAt ?? e.startedAt ?? e.createdAt,
      fromBackup: e.restoredAt != null,
    );
  }
}
