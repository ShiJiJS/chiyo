import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_credentials.dart';

enum WorkspaceExecutionState {
  preparing('准备中'),
  running('运行中'),
  exited('已退出'),
  prepareFailed('准备失败'),
  startFailed('启动失败'),
  unknown('执行结果未知');

  const WorkspaceExecutionState(this.label);
  final String label;
}

enum WorkspaceExecutionCleanup {
  notNeeded('无需清理'),
  needsCheck('待核对'),
  complete('已清理'),
  failed('清理失败');

  const WorkspaceExecutionCleanup(this.label);
  final String label;
}

/// Read-only, content-free metadata for one operation under a fixed grant.
/// A query never launches, replays, cleans material, or extends the grant.
class WorkspaceApprovalExecution {
  const WorkspaceApprovalExecution({
    required this.requestId,
    required this.grantId,
    required this.operationId,
    required this.credential,
    required this.plan,
    required this.createdAt,
    required this.state,
    required this.revision,
    required this.processEnded,
    required this.processStarted,
    required this.cleanup,
    this.exitCode,
    this.errorCode,
    this.observedAt,
    this.fromBackup = false,
  });
  final String requestId, grantId, operationId;
  final WorkspaceCredentialUseRequest credential;
  final WorkspaceCredentialReceiver plan;
  final DateTime createdAt;
  final DateTime? observedAt;
  final bool fromBackup;
  final WorkspaceExecutionState state;
  final WorkspaceExecutionCleanup cleanup;
  final int revision;
  final bool processEnded, processStarted;
  final int? exitCode;
  final String? errorCode;
  String get resultLabel => state == WorkspaceExecutionState.exited
      ? '已退出 · 退出码 ${exitCode ?? "未知"}'
      : state.label;
  String get bindingDigest => _hash([
    requestId,
    grantId,
    operationId,
    credential.ref.key,
    credential.credentialName,
    credential.materialVersion,
    credential.useGeneration,
    credential.delivery.name,
    credential.session.id,
    plan.id,
    plan.label,
    plan.executable,
    plan.workingDirectory,
    plan.arguments,
    plan.binding,
    createdAt.toUtc().toIso8601String(),
    fromBackup,
  ]);
  String get observationDigest => _hash([
    bindingDigest,
    revision,
    state.name,
    processStarted,
    processEnded,
    cleanup.name,
    exitCode,
    errorCode,
    observedAt?.toUtc().toIso8601String(),
  ]);
  String _hash(Object v) =>
      sha256.convert(utf8.encode(jsonEncode(v))).toString();
  bool get valid =>
      revision > 0 &&
      (observedAt == null || !observedAt!.isBefore(createdAt)) &&
      (state == WorkspaceExecutionState.exited
          ? exitCode != null && processStarted && processEnded
          : exitCode == null) &&
      (state != WorkspaceExecutionState.running ||
          processStarted && !processEnded) &&
      (!{
            WorkspaceExecutionState.prepareFailed,
            WorkspaceExecutionState.startFailed,
          }.contains(state) ||
          !processStarted);
  bool updates(WorkspaceApprovalExecution old) =>
      valid &&
      bindingDigest == old.bindingDigest &&
      (revision > old.revision ||
          revision == old.revision &&
              observationDigest == old.observationDigest);

  WorkspaceApprovalExecution observed({
    required int revision,
    required bool processEnded,
    required WorkspaceExecutionCleanup cleanup,
    DateTime? at,
  }) => WorkspaceApprovalExecution(
    requestId: requestId,
    grantId: grantId,
    operationId: operationId,
    credential: credential,
    plan: plan,
    createdAt: createdAt,
    state: state,
    revision: revision,
    processStarted: processStarted,
    processEnded: processEnded,
    cleanup: cleanup,
    exitCode: exitCode,
    errorCode: errorCode,
    observedAt: at ?? observedAt,
    fromBackup: fromBackup,
  );
  WorkspaceApprovalExecution asRestored() => WorkspaceApprovalExecution(
    requestId: requestId,
    grantId: grantId,
    operationId: operationId,
    credential: credential,
    plan: plan,
    createdAt: createdAt,
    state:
        {
          WorkspaceExecutionState.preparing,
          WorkspaceExecutionState.running,
        }.contains(state)
        ? WorkspaceExecutionState.unknown
        : state,
    revision: revision,
    processEnded: processEnded,
    processStarted: processStarted,
    cleanup: WorkspaceExecutionCleanup.notNeeded,
    exitCode: exitCode,
    errorCode: errorCode,
    observedAt: observedAt,
    fromBackup: true,
  );
}
