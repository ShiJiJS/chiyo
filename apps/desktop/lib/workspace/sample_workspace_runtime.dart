part of 'sample_workspace_source.dart';

/// Synthetic runtime registrations only. No native window, process, material,
/// database, filesystem or server is opened, stopped or removed here.
class SampleWorkspaceRuntime implements WorkspaceRuntimeSource {
  SampleWorkspaceRuntime(this.s);
  final SampleWorkspaceSource s;
  int _version = 1;
  bool get acceptingRequests =>
      _phase == WorkspaceRuntimePhase.running && _serviceAvailable;
  WorkspaceRuntimePhase _phase = WorkspaceRuntimePhase.running;
  bool _serviceAvailable = true,
      _menuBarAvailable = true,
      _windowHidden = false;
  final _copies = <String, WorkspaceCopyMaintenance>{};
  final _blockedCopies = <String>{}, _blockedMaterials = <String>{};
  final _plans =
      <String, ({int epoch, int revision, WorkspaceQuitPreview preview})>{};
  final _receipts = <String, WorkspaceRuntimeReceipt>{};
  bool loseNextReply = false;
  WorkspaceRuntimePhase? nextQuitPhase;
  WorkspaceFailure? nextMaintenanceFailure;
  Future<void> _ready() async {
    final epoch = s._epoch;
    await s._readable();
    if (epoch != s._epoch) {
      throw const WorkspaceFailure('cancelled', '资料来源已变化，请重新核对运行状态。');
    }
  }

  List<WorkspaceApprovalExecution> get _executions => [
    for (final rows in s._approvals._executions.values)
      for (final e in rows.values)
        if (!e.fromBackup) e,
  ]..sort((a, b) => a.operationId.compareTo(b.operationId));
  List<WorkspaceApprovalExecution> get _materials => _executions
      .where((e) => e.credential.delivery == WorkspaceCredentialDelivery.file)
      .toList();
  WorkspaceCopyMaintenance _project(WorkspaceCopyMaintenance e) {
    if (e.state == WorkspaceCopyState.released) return e;
    final a = s._approvals,
        r = a._all().where((r) => r.id == e.requestId).firstOrNull;
    final f = r == null ? null : a._facts[r.id];
    final active =
        s._approvals.now.isBefore(e.expiresAt) &&
        r != null &&
        f != null &&
        a
            ._scopes(r)
            .any(
              (x) =>
                  x.kind == WorkspaceApprovalScopeKind.file &&
                  x.record == e.record &&
                  f.files[x.id] == e.fileVersion &&
                  a._active(r, x, f),
            );
    return e.withState(
      active ? WorkspaceCopyState.active : WorkspaceCopyState.pending,
      reason: active
          ? null
          : e.reason ??
                (s._approvals.now.isBefore(e.expiresAt)
                    ? '授权已结束或范围失效，登记副本等待回收。'
                    : '副本期限已到，等待核查登记路径。'),
    );
  }

  @override
  Future<WorkspaceRuntimeStatus> status() async {
    await _ready();
    return WorkspaceRuntimeStatus(
      version: _version,
      phase: _phase,
      serviceAvailable:
          _phase == WorkspaceRuntimePhase.running && _serviceAvailable,
      menuBarAvailable: _menuBarAvailable,
      windowHidden: _windowHidden,
      materials: _materials,
      copies: _copies.values.map(_project),
      serviceReason: _phase == WorkspaceRuntimePhase.saveFailed
          ? '停止接收新申请；退出审计尚未保存，资料库保留打开。'
          : _phase != WorkspaceRuntimePhase.running
          ? '本机服务已停止，旧会话授权不会恢复。'
          : !_serviceAvailable
          ? '本机服务暂不可用，不能接收新申请或核查材料。'
          : null,
    );
  }

  WorkspaceQuitPreview _scope(String token) {
    final a = s._approvals, rows = a._all().toList(), sessions = <String>{};
    var grants = 0, pending = 0;
    for (final r in rows) {
      final f = a._facts[r.id],
          active = f != null && a._scopes(r).any((x) => a._active(r, x, f));
      final waiting = a._state(r) == WorkspaceApprovalState.pending;
      if (active) grants++;
      if (waiting) pending++;
      if (active || waiting) sessions.add(r.session.id);
    }
    final materials = _materials;
    return WorkspaceQuitPreview(
      token: token,
      version: _version,
      sessions: sessions.length,
      grants: grants,
      pendingRequests: pending,
      materials: materials
          .where(
            (e) =>
                e.cleanup != WorkspaceExecutionCleanup.complete &&
                e.cleanup != WorkspaceExecutionCleanup.notNeeded,
          )
          .length,
      copies: _copies.values
          .map(_project)
          .where((e) => e.state != WorkspaceCopyState.released)
          .length,
      unconfirmedProcesses: _executions.where((e) => !e.processEnded).length,
    );
  }

  @override
  Future<WorkspaceQuitPreview> previewQuit() async {
    await _ready();
    if (_phase == WorkspaceRuntimePhase.stopped ||
        _phase == WorkspaceRuntimePhase.terminationFailed) {
      throw const WorkspaceFailure('service_stopped', '服务已停止，请重试应用退出。');
    }
    final p = _scope(workspaceOperationId());
    // Only count metadata is leased; old views must not grow this table forever.
    if (_plans.length >= 32) {
      throw const WorkspaceFailure('preview_busy', '请先关闭原退出确认，再重新核对。');
    }
    _plans[p.token] = (
      epoch: s._epoch,
      revision: s._backupRevision,
      preview: p,
    );
    return p;
  }

  @override
  Future<void> releaseQuit(String token) async {
    _plans.remove(token);
  }

  @override
  Future<WorkspaceRuntimeReceipt> change(WorkspaceRuntimeChange c) async {
    await _ready();
    if (c.operationId.isEmpty || c.operationId.length > 200) {
      throw const WorkspaceFailure('validation', '运行操作身份无效。');
    }
    if (_receipts[c.operationId] case final old?) {
      if (!old.matches(c)) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能变更运行意图。');
      }
      return old;
    }
    if (c.expectedVersion != _version) {
      throw const WorkspaceFailure('conflict', '运行状态已变化，请重新读取。');
    }
    WorkspaceQuitPreview? scope;
    if (c.action == WorkspaceRuntimeAction.quit) {
      final plan = _plans[c.quitToken];
      if (plan == null ||
          plan.epoch != s._epoch ||
          plan.revision != s._backupRevision ||
          plan.preview.version != _version) {
        throw const WorkspaceFailure(
          'quit_changed',
          '确认后的会话或运行事实已变化，请重新核对，尚未退出。',
        );
      }
      scope = plan.preview;
    } else if (c.action == WorkspaceRuntimeAction.finishExit) {
      if (_phase != WorkspaceRuntimePhase.terminationFailed) {
        throw const WorkspaceFailure('conflict', '当前无需重试应用退出。');
      }
    } else {
      if (_phase != WorkspaceRuntimePhase.running || !_serviceAvailable) {
        throw const WorkspaceFailure(
          'service_unavailable',
          '本机服务不可用，原登记与资料保留。',
        );
      }
      if (c.action == WorkspaceRuntimeAction.hideWindow) {
        if (!s.settings.portablePreferences.background) {
          throw const WorkspaceFailure('quit_required', '关闭窗口将完全退出，请先核对退出范围。');
        }
        if (!_menuBarAvailable) {
          throw const WorkspaceFailure(
            'menu_bar_unavailable',
            '菜单栏入口不可用，窗口保持可见，避免无法重新打开。',
          );
        }
      }
      if (c.action == WorkspaceRuntimeAction.checkMaterials ||
          c.action == WorkspaceRuntimeAction.checkAttachments) {
        if (nextMaintenanceFailure case final failure?) {
          nextMaintenanceFailure = null;
          throw failure;
        }
      }
    }
    if (nextQuitPhase != null &&
        !{
          WorkspaceRuntimePhase.saveFailed,
          WorkspaceRuntimePhase.terminationFailed,
        }.contains(nextQuitPhase)) {
      throw const WorkspaceFailure('validation', '退出故障状态无效。');
    }
    s._beforeApprovalWrite();
    var checked = 0, released = 0, retained = 0;
    switch (c.action) {
      case WorkspaceRuntimeAction.checkMaterials:
        for (final e in _materials) {
          if (e.cleanup == WorkspaceExecutionCleanup.complete ||
              e.cleanup == WorkspaceExecutionCleanup.notNeeded) {
            continue;
          }
          if (!e.processEnded) {
            retained++;
            continue;
          }
          checked++;
          final blocked = _blockedMaterials.contains(e.operationId);
          if (blocked) {
            retained++;
          } else {
            released++;
          }
          s._approvals._executions[e.requestId]![e.operationId] = e.observed(
            revision: e.revision + 1,
            processEnded: e.processEnded,
            cleanup: blocked
                ? WorkspaceExecutionCleanup.failed
                : WorkspaceExecutionCleanup.complete,
            at: s._approvals.now,
          );
        }
      case WorkspaceRuntimeAction.checkAttachments:
        for (final e in _copies.values.toList().map(_project)) {
          if (e.state == WorkspaceCopyState.released) continue;
          if (e.state == WorkspaceCopyState.active) {
            retained++;
            continue;
          }
          checked++;
          final blocked = _blockedCopies.contains(e.id);
          if (blocked) {
            retained++;
          } else {
            released++;
          }
          _copies[e.id] = e.withState(
            blocked ? WorkspaceCopyState.pending : WorkspaceCopyState.released,
            reason: blocked ? '登记路径身份核查失败，保留登记并可重试。' : null,
          );
        }
      case WorkspaceRuntimeAction.hideWindow:
        _windowHidden = true;
      case WorkspaceRuntimeAction.showWindow:
        _windowHidden = false;
      case WorkspaceRuntimeAction.finishExit:
        _phase = nextQuitPhase == WorkspaceRuntimePhase.terminationFailed
            ? WorkspaceRuntimePhase.terminationFailed
            : WorkspaceRuntimePhase.stopped;
        nextQuitPhase = null;
      case WorkspaceRuntimeAction.quit:
        // Model the production ordering: capabilities end first. A failed
        // audit save keeps data open, without reviving ended authorization.
        s._approvals._ended.addAll(
          s._approvals._all().map((r) => r.session.id),
        );
        _windowHidden = false;
        _phase = nextQuitPhase ?? WorkspaceRuntimePhase.stopped;
        nextQuitPhase = null;
        _plans.remove(c.quitToken);
    }
    final r = WorkspaceRuntimeReceipt(
      operationId: c.operationId,
      commandDigest: c.digest,
      action: c.action,
      expectedVersion: c.expectedVersion,
      version: ++_version,
      phase: _phase,
      windowHidden: _windowHidden,
      checked: checked,
      released: released,
      retained: retained,
      quitScope: scope,
    );
    _receipts[c.operationId] = r;
    s._changes.add(null);
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure(
        'unknown_outcome',
        '运行操作结果未知，请核对原操作，不要重复执行。',
      );
    }
    return r;
  }

  @override
  Future<WorkspaceRuntimeReceipt?> receipt(String id) async {
    await _ready();
    return _receipts[id];
  }

  /// Composition-only fault inputs. No page mutates a fake platform directly.
  void setAvailability({bool? service, bool? menuBar}) {
    if (service != null) _serviceAvailable = service;
    if (menuBar != null) {
      _menuBarAvailable = menuBar;
      if (!menuBar) _windowHidden = false;
    }
    _version++;
    s._changes.add(null);
  }

  void allowCleanup() {
    _blockedCopies.clear();
    _blockedMaterials.clear();
    s._changes.add(null);
  }

  void resetCurrent() {
    _copies.clear();
    _plans.clear();
    _blockedCopies.clear();
    _blockedMaterials.clear();
    _phase = WorkspaceRuntimePhase.running;
    _serviceAvailable = _menuBarAvailable = true;
    _windowHidden = false;
    nextQuitPhase = null;
    nextMaintenanceFailure = null;
    loseNextReply = false;
    _version++;
  }

  void resumePreview() {
    _phase = WorkspaceRuntimePhase.running;
    _serviceAvailable = true;
    _windowHidden = false;
    s._credentials.startNewSessions();
    _version++;
    s._changes.add(null);
  }
}

extension SampleRuntimePreparation on SampleWorkspaceSource {
  Future<void> prepareRuntimeMaintenance() async {
    await replaceFixture(sampleWorkspaceJson);
    for (final id in ['server', 'resume']) {
      final d = await approvals.read(id);
      await approvals.change(
        WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: id,
          reviewToken: d.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: d.scopes
              .where((x) => x.requested && x.available)
              .map((x) => x.id),
          fileVersions: {
            for (final x in d.scopes.where(
              (x) => x.kind == WorkspaceApprovalScopeKind.file,
            ))
              x.id: x.fileVersions.last.ref.version,
          },
        ),
      );
    }
    _approvals.demonstrateExecutions('server');
    final ended = _approvals._executions['server']!.values.first;
    _approvals._executions['server']![ended.operationId] = ended.observed(
      revision: ended.revision + 1,
      processEnded: true,
      cleanup: WorkspaceExecutionCleanup.failed,
      at: _approvals.now,
    );
    runtime._blockedMaterials.add(ended.operationId);
    final r = _approvals._input('resume'),
        f = _approvals._facts[r.id]!,
        scope = f.scopes.values.firstWhere(
          (x) => x.kind == WorkspaceApprovalScopeKind.file,
        );
    for (final id in ['copy-active', 'copy-pending']) {
      final copy = WorkspaceCopyMaintenance(
        id: id,
        requestId: r.id,
        record: scope.record,
        name: scope.recordName,
        fileVersion: f.files[scope.id]!,
        expiresAt: id == 'copy-active'
            ? f.fieldEnd!
            : _approvals.now.subtract(const Duration(minutes: 1)),
        state: WorkspaceCopyState.pending,
      );
      runtime._copies[id] = copy;
    }
    runtime._blockedCopies.add('copy-pending');
    _changes.add(null);
  }
}
