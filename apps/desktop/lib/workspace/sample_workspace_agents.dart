part of 'sample_workspace_source.dart';

enum SampleAgentScenario {
  ready,
  missingCli,
  missingSkill,
  missingHooks,
  untrustedHooks,
  changedCommand,
  noAssociation,
  bindingMismatch,
  ended,
  freshSession,
}

/// Synthetic observations, not a host trust store or an installer. Private
/// association files, credentials, hooks, user configs and transcripts are never read.
class SampleWorkspaceAgents implements WorkspaceAgentsSource {
  SampleWorkspaceAgents(this.s);
  final SampleWorkspaceSource s;
  int _version = 1, _definition = 1;
  WorkspaceAgentCheck _cli = WorkspaceAgentCheck.ready,
      _skill = WorkspaceAgentCheck.ready,
      _hookState = WorkspaceAgentCheck.ready;
  String? _sessionId = 'session-maintenance';
  String _sessionLabel = '当前维护会话';
  bool _bindingMatches = true;
  WorkspaceFailure? nextReadFailure, nextDiagnosticFailure, nextSessionFailure;
  Future<void> _ready() async {
    final epoch = s._epoch;
    await s._readable();
    if (epoch != s._epoch) {
      throw const WorkspaceFailure('cancelled', '资料来源已变化，请重新检测接入状态。');
    }
  }

  int get _revision => _version + s._backupRevision;
  WorkspaceAgentSession _session() {
    if (_sessionId == null || !_bindingMatches) {
      return WorkspaceAgentSession(
        state: _sessionId == null
            ? WorkspaceAgentSessionState.missing
            : WorkspaceAgentSessionState.mismatch,
        totalRequests: 0,
        pendingRequests: 0,
        activeGrants: 0,
      );
    }
    final a = s._approvals,
        rows = a._all().where((r) => r.session.id == _sessionId).toList(),
        ended = a._ended.contains(_sessionId);
    return WorkspaceAgentSession(
      state: ended
          ? WorkspaceAgentSessionState.ended
          : WorkspaceAgentSessionState.linked,
      id: _sessionId,
      label: _sessionLabel,
      totalRequests: rows.length,
      pendingRequests: rows
          .where((r) => a._state(r) == WorkspaceApprovalState.pending)
          .length,
      activeGrants: rows.where((r) {
        final f = a._facts[r.id];
        return f != null && a._scopes(r).any((x) => a._active(r, x, f));
      }).length,
    );
  }

  WorkspaceAgentOverview _overview() => WorkspaceAgentOverview(
    version: _revision,
    observedAt: s._approvals.now,
    serviceAvailable: s.runtime.acceptingRequests,
    serviceReason: s.runtime.acceptingRequests
        ? null
        : '本机服务未接收新申请；连接观察不代表资料访问许可。',
    cli: _cli,
    skill: _skill,
    hooks: [
      for (final (event, timeout) in [
        ('SessionStart', 15),
        ('SubagentStart', 5),
        ('SessionEnd', 3),
      ])
        WorkspaceAgentHook(
          event: event,
          state: _hookState,
          command:
              "'/合成工具/Agent Info/info-codex-hook${_definition == 1 ? '' : '-updated'}'",
          definitionId: 'synthetic-definition-$_definition',
          trustedDefinitionId: _hookState == WorkspaceAgentCheck.ready
              ? 'synthetic-definition-1'
              : null,
          timeoutSeconds: timeout,
          matcher: event == 'SessionStart'
              ? r'^(startup|resume|clear|compact|fork)$'
              : null,
        ),
    ],
    session: _session(),
  );
  @override
  Future<WorkspaceAgentOverview> read({String? sessionId}) async {
    await _ready();
    if (nextReadFailure case final error?) {
      nextReadFailure = null;
      throw error;
    }
    return _overview();
  }

  @override
  Future<WorkspaceAgentOverview> diagnose(int expectedVersion) async {
    await _ready();
    if (nextDiagnosticFailure case final error?) {
      nextDiagnosticFailure = null;
      throw error;
    }
    final current = _overview();
    if (expectedVersion != current.version) {
      throw const WorkspaceFailure('observation_changed', '接入观察已变化，请重新读取后检测。');
    }
    return current;
  }

  @override
  Future<WorkspaceAgentSessionDetail> currentSession(
    int expectedVersion,
  ) async {
    await _ready();
    if (nextSessionFailure case final error?) {
      nextSessionFailure = null;
      throw error;
    }
    final current = _overview();
    if (expectedVersion != current.version) {
      throw const WorkspaceFailure(
        'observation_changed',
        '当前聊天关联已变化，请重新读取后查看。',
      );
    }
    final a = s._approvals;
    return WorkspaceAgentSessionDetail(
      overviewFingerprint: current.fingerprint,
      session: current.session,
      requests: [
        if (current.session.id != null)
          for (final r in a._all().where(
            (r) => r.session.id == current.session.id,
          ))
            a._summary(r),
      ],
    );
  }

  void resetCurrent() {
    _version++;
    _definition = 1;
    _cli = _skill = _hookState = WorkspaceAgentCheck.ready;
    _sessionId = 'session-maintenance';
    _sessionLabel = '当前维护会话';
    _bindingMatches = true;
    nextReadFailure = nextDiagnosticFailure = nextSessionFailure = null;
  }

  void invalidateAssociation() {
    _version++;
    _sessionId = null;
    _bindingMatches = true;
  }

  Future<void> setScenario(SampleAgentScenario value) async {
    await _ready();
    final epoch = s._epoch;
    resetCurrent();
    switch (value) {
      case SampleAgentScenario.ready:
        break;
      case SampleAgentScenario.missingCli:
        _cli = WorkspaceAgentCheck.missing;
      case SampleAgentScenario.missingSkill:
        _skill = WorkspaceAgentCheck.missing;
      case SampleAgentScenario.missingHooks:
        _hookState = WorkspaceAgentCheck.missing;
      case SampleAgentScenario.untrustedHooks:
        _hookState = WorkspaceAgentCheck.untrusted;
      case SampleAgentScenario.changedCommand:
        _definition = 2;
      case SampleAgentScenario.noAssociation:
        _sessionId = null;
      case SampleAgentScenario.bindingMismatch:
        _bindingMatches = false;
      case SampleAgentScenario.ended:
        s._approvals._ended.add(_sessionId!);
      case SampleAgentScenario.freshSession:
        s._credentials.startNewSessions();
        final current = (await s.credentials.sessions()).first;
        if (epoch != s._epoch) {
          throw const WorkspaceFailure('cancelled', '资料来源已变化，未关联旧聊天。');
        }
        _sessionId = current.id;
        _sessionLabel = current.label;
    }
    s._changes.add(null);
  }
}
