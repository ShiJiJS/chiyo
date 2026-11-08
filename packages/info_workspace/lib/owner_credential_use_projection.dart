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
    if (r.restoredAt != null) {
      return WorkspaceCredentialRequestState.unavailable;
    }
    final grant = owner.credentialGrantState(r);
    final fields = owner.credentialFieldGrantState(r);
    // The ordinary half has its own deadline. Keep its remaining permission
    // visible/revocable when the credential half expires or is invalidated.
    if (fields == 'available' && grant != 'available') {
      return WorkspaceCredentialRequestState.partiallyApproved;
    }
    if (r.invalidatedCode == 'grant_revoked') {
      return WorkspaceCredentialRequestState.revoked;
    }
    if (grant == 'available') return WorkspaceCredentialRequestState.approved;
    if (grant == 'expired' ||
        !r.credentialApproved && fields == 'expired' ||
        status == 'expired') {
      return WorkspaceCredentialRequestState.expired;
    }
    final session = owner.credentialRequestSessionId(r.id);
    if (session == null ||
        !owner.sessions.any((s) => s.id == session && !s.ended)) {
      return WorkspaceCredentialRequestState.sessionEnded;
    }
    if (r.credentialApproved) {
      if (owner.recycledCredentials.any((c) => c.id == r.credentialId)) {
        return WorkspaceCredentialRequestState.recycled;
      }
      final credential = owner.credentials
          .where((c) => c.id == r.credentialId)
          .firstOrNull;
      if (credential == null) {
        return WorkspaceCredentialRequestState.unavailable;
      }
      if (!credential.enabled) return WorkspaceCredentialRequestState.disabled;
      if (credential.version != r.version ||
          credential.useGeneration != r.useGeneration) {
        return WorkspaceCredentialRequestState.superseded;
      }
    }
    // A consumed legacy operation or unavailable material is not a live grant
    // or an explicit owner revocation. Retain the decision as history only.
    return WorkspaceCredentialRequestState.unavailable;
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
      supportsSessionValidity: r.supportsSessionValidity,
      minutes: r.credentialValidity == core.CredentialUseValidity.session
          ? null
          : r.credentialExpiresAt != null && r.decidedAt != null
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
