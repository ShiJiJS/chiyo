import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import '../desktop_runtime.dart';
import 'package:info_workspace/owner_runtime_materials.dart';
import 'workspace_source.dart';

/// Actual runtime observations and explicit maintenance. No arbitrary paths,
/// process signals, launch replay or reconstruction of capabilities.
class OwnerWorkspaceRuntime implements WorkspaceRuntimeSource {
  OwnerWorkspaceRuntime({required this.runtime, required this.changed})
    : owner = runtime.service.owner,
      _scope = runtime.service.owner.captureLibraryScope(),
      _materials = OwnerRuntimeMaterials(runtime.service.owner);
  final DesktopRuntime runtime;
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  final OwnerRuntimeMaterials _materials;
  final void Function() changed;
  final _receipts = <String, WorkspaceRuntimeReceipt>{};
  final _attempts = <String, String>{};
  final _plans = <String, (WorkspaceQuitPreview, String)>{};
  int _version = 1;
  String? _signature;
  WorkspaceRuntimeStatus? _last;
  bool _busy = false;
  WorkspaceRuntimePhase get _phase => runtime.shutdownFailed
      ? runtime.stopped
            ? WorkspaceRuntimePhase.terminationFailed
            : WorkspaceRuntimePhase.saveFailed
      : runtime.stopped
      ? WorkspaceRuntimePhase.stopped
      : WorkspaceRuntimePhase.running;
  void _check() {
    if (!_scope.isCurrent &&
        !runtime.stopped &&
        !runtime.quitting &&
        !runtime.shutdownFailed) {
      throw const WorkspaceFailure('library_changed', '资料库已替换，请重新打开运行页面。');
    }
  }

  WorkspaceRuntimeStatus _observe() {
    _check();
    final available = !runtime.stopped && owner.serviceAvailable;
    final executions = available
        ? owner.credentialExecutions.where((e) => e.restoredAt == null).toList()
        : <core.CredentialExecution>[];
    final materials = available
        ? _materials.materials()
        : _last?.materials ?? <WorkspaceApprovalExecution>[];
    final copies = available
        ? _materials.copies()
        : _last?.copies ?? <WorkspaceCopyMaintenance>[];
    final signature = jsonEncode([
      _phase.name,
      available,
      runtime.availability.tray,
      runtime.windowHidden,
      runtime.ownerFileCleanupFailed,
      runtime.informationDeliveryCleanupFailed,
      runtime.runtimeMaterialCleanupFailed,
      for (final e in materials) e.observationDigest,
      for (final c in copies) [c.id, c.state.name, c.reason],
      if (available) ...[
        for (final e in executions) [e.id, e.state, e.cleanupState, e.exitCode],
        for (final s in owner.sessions) [s.id, s.ended],
        for (final r in owner.requests) [r.id, r.state.name, r.sessionEnded],
        for (final r in owner.credentialUseRequests)
          [r.id, owner.credentialUseState(r), owner.credentialGrantState(r)],
        for (final t in owner.organizationTasks)
          [t.id, owner.organizationState(t).name],
        owner.desktopPreferences.version,
      ],
    ]);
    if (_signature != null && signature != _signature) _version++;
    _signature = signature;
    return _last = WorkspaceRuntimeStatus(
      version: _version,
      phase: _phase,
      serviceAvailable: available,
      menuBarAvailable: runtime.availability.tray,
      windowHidden: runtime.windowHidden,
      materials: materials,
      copies: copies,
      serviceReason: runtime.shutdownFailed
          ? runtime.stopped
                ? '服务已停止，系统退出尚未成功，可重试退出。'
                : '退出保存未完成，保留原资料库等待重试。'
          : !available
          ? '本机服务已停止，不再接收申请。'
          : runtime.runtimeMaterialCleanupFailed ||
                runtime.informationDeliveryCleanupFailed ||
                runtime.ownerFileCleanupFailed
          ? '本机服务可用；部分登记材料待核对，未假称清理完成。'
          : null,
    );
  }

  @override
  Future<WorkspaceRuntimeStatus> status() async => _observe();
  WorkspaceQuitPreview _quitScope(String token, WorkspaceRuntimeStatus s) =>
      WorkspaceQuitPreview(
        token: token,
        version: s.version,
        sessions: s.serviceAvailable
            ? owner.sessions.where((s) => !s.ended).length
            : 0,
        grants: !s.serviceAvailable
            ? 0
            : owner.informationRequests
                      .where((r) => r.state == core.AccessRequestState.approved)
                      .length +
                  owner.credentialUseRequests
                      .where(
                        (r) => owner.credentialGrantState(r) == 'available',
                      )
                      .length,
        pendingRequests: s.serviceAvailable
            ? owner.queryInbox(limit: 1).pendingCount
            : 0,
        materials: s.materials
            .where(
              (e) => !{
                WorkspaceExecutionCleanup.complete,
                WorkspaceExecutionCleanup.notNeeded,
              }.contains(e.cleanup),
            )
            .length,
        copies: s.copies
            .where((c) => c.state != WorkspaceCopyState.released)
            .length,
        unconfirmedProcesses: !s.serviceAvailable
            ? s.materials.where((e) => !e.processEnded).length
            : owner.credentialExecutions
                  .where(
                    (e) =>
                        e.restoredAt == null &&
                        {'preparing', 'running', 'unknown'}.contains(e.state),
                  )
                  .length,
      );
  @override
  Future<WorkspaceQuitPreview> previewQuit() async {
    final s = _observe();
    if (s.closed ||
        !s.serviceAvailable && s.phase != WorkspaceRuntimePhase.saveFailed) {
      throw const WorkspaceFailure('service_unavailable', '当前不能核对退出范围。');
    }
    final p = _quitScope(workspaceOperationId(), s);
    _plans.clear();
    _plans[p.token] = (p, _signature!);
    return p;
  }

  @override
  Future<void> releaseQuit(String token) async {
    _plans.remove(token);
  }

  @override
  Future<WorkspaceRuntimeReceipt?> receipt(String id) async {
    _check();
    if (_receipts[id] case final r?) return r;
    if (_attempts.containsKey(id)) {
      throw const WorkspaceFailure('unknown_outcome', '原运行操作结果仍无法确认，请勿重复提交。');
    }
    return null;
  }

  @override
  Future<WorkspaceRuntimeReceipt> change(WorkspaceRuntimeChange c) async {
    _check();
    if (c.operationId.isEmpty || c.operationId.length > 200) {
      throw const WorkspaceFailure('validation', '运行操作身份无效。');
    }
    if (_receipts[c.operationId] case final old?) {
      if (old.commandDigest != c.digest) {
        throw const WorkspaceFailure('operation_conflict', '原操作不能更换意图。');
      }
      return old;
    }
    if (_attempts.containsKey(c.operationId)) {
      throw const WorkspaceFailure('unknown_outcome', '请继续核对原运行操作。');
    }
    if (_busy) throw const WorkspaceFailure('busy', '运行操作正在处理，请稍后重试。');
    final before = _observe();
    if (before.version != c.expectedVersion) {
      throw const WorkspaceFailure('conflict', '运行状态已变化，请重新读取。');
    }
    WorkspaceQuitPreview? quit;
    if (c.action == WorkspaceRuntimeAction.quit) {
      final p = _plans[c.quitToken];
      if (p == null ||
          p.$2 != _signature ||
          p.$1.version != c.expectedVersion) {
        throw const WorkspaceFailure('quit_changed', '退出范围已变化，请重新核对。');
      }
      quit = p.$1;
    } else if (c.action == WorkspaceRuntimeAction.finishExit) {
      if (before.phase != WorkspaceRuntimePhase.terminationFailed) {
        throw const WorkspaceFailure('conflict', '当前无需重试系统退出。');
      }
    } else if (!before.serviceAvailable ||
        before.phase != WorkspaceRuntimePhase.running) {
      throw const WorkspaceFailure('service_unavailable', '服务当前不可用，保留原登记。');
    }
    if (c.action == WorkspaceRuntimeAction.hideWindow &&
        (!owner.desktopPreferences.background || !before.menuBarAvailable)) {
      throw const WorkspaceFailure('quit_required', '关闭方式或菜单栏状态已变化，请重新核对退出范围。');
    }
    _busy = true;
    _attempts[c.operationId] = c.digest;
    try {
      switch (c.action) {
        case WorkspaceRuntimeAction.checkMaterials:
          await runtime.reconcileRuntimeMaterialCleanup();
        case WorkspaceRuntimeAction.checkAttachments:
          await runtime.reconcileInformationFiles();
        case WorkspaceRuntimeAction.hideWindow:
          if (!await runtime.hideWorkingWindow()) {
            throw const WorkspaceFailure(
              'menu_bar_unavailable',
              '菜单栏不可用，窗口保持可见。',
            );
          }
        case WorkspaceRuntimeAction.showWindow:
          await runtime.showWorkingWindow();
        case WorkspaceRuntimeAction.quit:
        case WorkspaceRuntimeAction.finishExit:
          await runtime.quit();
      }
      final after = _observe();
      // Even a no-op observation check is a distinct completed attempt.
      if (_version <= c.expectedVersion) _version = c.expectedVersion + 1;
      final oldIds = c.action == WorkspaceRuntimeAction.checkMaterials
          ? before.materials
                .where(
                  (e) => !{
                    WorkspaceExecutionCleanup.complete,
                    WorkspaceExecutionCleanup.notNeeded,
                  }.contains(e.cleanup),
                )
                .map((e) => e.operationId)
                .toSet()
          : c.action == WorkspaceRuntimeAction.checkAttachments
          ? before.copies
                .where((e) => e.state != WorkspaceCopyState.released)
                .map((e) => e.id)
                .toSet()
          : <String>{};
      final remaining = c.action == WorkspaceRuntimeAction.checkMaterials
          ? after.materials
                .where(
                  (e) =>
                      oldIds.contains(e.operationId) &&
                      !{
                        WorkspaceExecutionCleanup.complete,
                        WorkspaceExecutionCleanup.notNeeded,
                      }.contains(e.cleanup),
                )
                .length
          : after.copies
                .where(
                  (e) =>
                      oldIds.contains(e.id) &&
                      e.state != WorkspaceCopyState.released,
                )
                .length;
      final r = WorkspaceRuntimeReceipt(
        operationId: c.operationId,
        commandDigest: c.digest,
        action: c.action,
        expectedVersion: c.expectedVersion,
        version: _version,
        phase: _phase,
        windowHidden: runtime.windowHidden,
        checked: oldIds.length,
        released: oldIds.length - remaining,
        retained: remaining,
        quitScope: quit,
      );
      _receipts[c.operationId] = r;
      changed();
      return r;
    } on WorkspaceFailure {
      rethrow;
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '无法确认原运行操作结果，请先核对。');
    } finally {
      _busy = false;
    }
  }
}
