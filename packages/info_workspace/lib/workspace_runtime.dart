import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_approval_execution.dart';
import 'workspace_records.dart';
import 'workspace_credential_programs.dart';

/// Original execution-device observations. No OS identity, cleanup handle,
/// material or ability to act on that device is carried by this row.
class WorkspaceRuntimeProgram {
  const WorkspaceRuntimeProgram(
    this.operation, {
    required this.processUnconfirmed,
  });
  final WorkspaceCredentialProgramOperation operation;
  final bool processUnconfirmed;
  bool get holdsMaterial =>
      operation.plan.requiresManagedFiles &&
      !{'not_needed', 'complete'}.contains(operation.cleanup);
  bool get valid =>
      operation.valid &&
      !operation.fromBackup &&
      (!{'preparing', 'running'}.contains(operation.state) ||
          processUnconfirmed);
  String get processLabel => processUnconfirmed
      ? '进程尚未确认结束'
      : operation.processStarted
      ? '进程已确认结束'
      : operation.state == 'unknown'
      ? '进程已结束，启动结果未知'
      : '程序未启动';
  String get observationDigest {
    final value = operation.toJson()..remove('observedAt');
    return sha256
        .convert(utf8.encode(jsonEncode([value, processUnconfirmed])))
        .toString();
  }

  Map<String, Object?> toJson() => {
    'operation': operation.toJson(),
    'processUnconfirmed': processUnconfirmed,
  };
  factory WorkspaceRuntimeProgram.fromJson(Map<String, dynamic> value) {
    if (value.length != 2 ||
        value['operation'] is! Map<String, dynamic> ||
        value['processUnconfirmed'] is! bool) {
      throw const FormatException('Invalid runtime program');
    }
    final result = WorkspaceRuntimeProgram(
      WorkspaceCredentialProgramOperation.fromJson(
        value['operation'] as Map<String, dynamic>,
      ),
      processUnconfirmed: value['processUnconfirmed'] as bool,
    );
    if (!result.valid) throw const FormatException('Invalid runtime program');
    return result;
  }
}

enum WorkspaceRuntimePhase {
  running('运行中'),
  saveFailed('退出保存未完成'),
  terminationFailed('服务已停止，应用退出未完成'),
  stopped('已停止');

  const WorkspaceRuntimePhase(this.label);
  final String label;
}

enum WorkspaceRuntimeAction {
  checkMaterials,
  checkAttachments,
  hideWindow,
  showWindow,
  quit,
  finishExit,
}

enum WorkspaceCopyState {
  active('授权有效，副本保留'),
  pending('待回收'),
  released('登记路径已移除');

  const WorkspaceCopyState(this.label);
  final String label;
}

/// Runtime registration metadata, never a path, contents or delivery capability.
class WorkspaceCopyMaintenance {
  const WorkspaceCopyMaintenance({
    required this.id,
    required this.requestId,
    required this.record,
    required this.name,
    required this.fileVersion,
    required this.expiresAt,
    required this.state,
    this.reason,
  });
  final String id, requestId, name;
  final WorkspaceRecordRef record;
  final int fileVersion;
  final DateTime expiresAt;
  final WorkspaceCopyState state;
  final String? reason;
  WorkspaceCopyMaintenance withState(
    WorkspaceCopyState value, {
    String? reason,
  }) => WorkspaceCopyMaintenance(
    id: id,
    requestId: requestId,
    record: record,
    name: name,
    fileVersion: fileVersion,
    expiresAt: expiresAt,
    state: value,
    reason: reason,
  );
}

enum WorkspaceOwnerCopyKind { open, save }

/// Only this App's private file coordination metadata. Ordinary user-saved
/// output is not a disposable copy; only its temporary staging is maintained.
class WorkspaceOwnerCopyMaintenance {
  const WorkspaceOwnerCopyMaintenance({
    required this.id,
    required this.name,
    required this.fileVersion,
    required this.kind,
    required this.active,
    required this.uncertain,
  });
  final String id, name;
  final int fileVersion;
  final WorkspaceOwnerCopyKind kind;
  final bool active, uncertain;
  Map<String, Object?> get json => {
    'id': id,
    'name': name,
    'fileVersion': fileVersion,
    'kind': kind.name,
    'active': active,
    'uncertain': uncertain,
  };
}

class WorkspaceRuntimeStatus {
  WorkspaceRuntimeStatus({
    required this.version,
    required this.phase,
    required this.serviceAvailable,
    required this.menuBarAvailable,
    required this.windowHidden,
    required Iterable<WorkspaceApprovalExecution> materials,
    required Iterable<WorkspaceCopyMaintenance> copies,
    this.serviceReason,
    this.independentServer = false,
    this.unconfirmedProcesses = 0,
    Iterable<WorkspaceRuntimeProgram> programs = const [],
    Iterable<WorkspaceOwnerCopyMaintenance> ownerCopies = const [],
  }) : programs = List.unmodifiable(programs),
       ownerCopies = List.unmodifiable(ownerCopies),
       materials = List.unmodifiable(materials),
       copies = List.unmodifiable(copies);
  final int version;
  final WorkspaceRuntimePhase phase;
  final bool serviceAvailable, menuBarAvailable, windowHidden;
  final String? serviceReason;
  final bool independentServer;
  final int unconfirmedProcesses;
  final List<WorkspaceRuntimeProgram> programs;
  final List<WorkspaceOwnerCopyMaintenance> ownerCopies;
  final List<WorkspaceApprovalExecution> materials;
  final List<WorkspaceCopyMaintenance> copies;
  int get maintenanceCount => materials.length + programs.length;
  Set<String> get legacyMaterialKeys => {
    for (final e in materials)
      if (!{
        WorkspaceExecutionCleanup.complete,
        WorkspaceExecutionCleanup.notNeeded,
      }.contains(e.cleanup))
        jsonEncode(['legacy', e.requestId, e.operationId]),
  };
  Set<String> get programMaterialKeys => {
    for (final p in programs)
      if (p.holdsMaterial)
        jsonEncode(['program', p.operation.requestId, p.operation.operationId]),
  };
  Set<String> get pendingMaterialKeys => {
    ...legacyMaterialKeys,
    ...programMaterialKeys,
  };
  bool get closed =>
      phase == WorkspaceRuntimePhase.stopped ||
      phase == WorkspaceRuntimePhase.terminationFailed;
}

class WorkspaceQuitPreview {
  const WorkspaceQuitPreview({
    required this.token,
    required this.version,
    required this.sessions,
    required this.grants,
    required this.pendingRequests,
    required this.materials,
    required this.copies,
    required this.unconfirmedProcesses,
    this.ownerCopies = 0,
  });
  final String token;
  final int ownerCopies;
  final int version,
      sessions,
      grants,
      pendingRequests,
      materials,
      copies,
      unconfirmedProcesses;
  Map<String, Object?> get counts => {
    'sessions': sessions,
    'grants': grants,
    'pendingRequests': pendingRequests,
    'materials': materials,
    'copies': copies,
    'unconfirmedProcesses': unconfirmedProcesses,
    'ownerCopies': ownerCopies,
  };
  bool get valid =>
      token.isNotEmpty &&
      version > 0 &&
      [
        sessions,
        grants,
        pendingRequests,
        materials,
        copies,
        unconfirmedProcesses,
        ownerCopies,
      ].every((n) => n >= 0);
}

class WorkspaceRuntimeChange {
  const WorkspaceRuntimeChange({
    required this.operationId,
    required this.action,
    required this.expectedVersion,
    this.quitToken,
  });
  final String operationId;
  final WorkspaceRuntimeAction action;
  final int expectedVersion;
  final String? quitToken;
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'operationId': operationId,
            'action': action.name,
            'expectedVersion': expectedVersion,
            'quitToken': quitToken,
          }),
        ),
      )
      .toString();
}

/// Facts about the original attempt. A saved quit attempt can still have a
/// failed save/termination phase; it is never presented as full exit success.
class WorkspaceRuntimeReceipt {
  const WorkspaceRuntimeReceipt({
    required this.operationId,
    required this.commandDigest,
    required this.action,
    required this.expectedVersion,
    required this.version,
    required this.phase,
    required this.windowHidden,
    this.checked = 0,
    this.released = 0,
    this.retained = 0,
    this.quitScope,
  });
  final String operationId, commandDigest;
  final WorkspaceRuntimeAction action;
  final int expectedVersion, version, checked, released, retained;
  final WorkspaceRuntimePhase phase;
  final bool windowHidden;
  final WorkspaceQuitPreview? quitScope;
  bool matches(WorkspaceRuntimeChange c) =>
      operationId == c.operationId &&
      commandDigest == c.digest &&
      action == c.action &&
      expectedVersion == c.expectedVersion &&
      version > expectedVersion &&
      checked >= 0 &&
      released >= 0 &&
      retained >= 0 &&
      released <= checked &&
      (action != WorkspaceRuntimeAction.finishExit ||
          phase == WorkspaceRuntimePhase.stopped ||
          phase == WorkspaceRuntimePhase.terminationFailed) &&
      (action != WorkspaceRuntimeAction.quit ||
          phase != WorkspaceRuntimePhase.running &&
              !windowHidden &&
              quitScope != null &&
              quitScope!.valid &&
              quitScope!.token == c.quitToken &&
              quitScope!.version == c.expectedVersion);
}

abstract interface class WorkspaceRuntimeSource {
  Future<WorkspaceRuntimeStatus> status();
  Future<WorkspaceQuitPreview> previewQuit();
  Future<void> releaseQuit(String token);
  Future<WorkspaceRuntimeReceipt> change(WorkspaceRuntimeChange change);

  /// Null confirms non-submission. Lookup failure must throw, never imply retry.
  Future<WorkspaceRuntimeReceipt?> receipt(String operationId);
}
