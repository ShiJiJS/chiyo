import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_approvals.dart';

enum WorkspaceAgentCheck {
  ready('已就绪'),
  missing('未安装'),
  untrusted('待审查信任'),
  changed('定义已变更'),
  unavailable('无法核对');

  const WorkspaceAgentCheck(this.label);
  final String label;
}

enum WorkspaceAgentSessionState {
  linked('已关联'),
  missing('尚未关联'),
  mismatch('绑定不符'),
  ended('会话已结束');

  const WorkspaceAgentSessionState(this.label);
  final String label;
}

enum WorkspaceAgentConnection {
  ready('已连接'),
  serviceUnavailable('服务不可用'),
  toolsMissing('接入工具未就绪'),
  hooksUntrusted('会话 hooks 未就绪'),
  associationMissing('等待聊天关联'),
  associationMismatch('聊天绑定无法核对'),
  sessionEnded('会话已结束');

  const WorkspaceAgentConnection(this.label);
  final String label;
}

enum WorkspaceAgentView { setup, rules, diagnostics, session }

class WorkspaceAgentHook {
  const WorkspaceAgentHook({
    required this.event,
    required this.state,
    required this.command,
    required this.definitionId,
    required this.timeoutSeconds,
    this.trustedDefinitionId,
    this.matcher,
  });
  final String event, command, definitionId;
  final String? trustedDefinitionId, matcher;
  final int timeoutSeconds;
  final WorkspaceAgentCheck state;
  WorkspaceAgentCheck get observedState => state != WorkspaceAgentCheck.ready
      ? state
      : command.trim().isEmpty || definitionId.isEmpty || timeoutSeconds <= 0
      ? WorkspaceAgentCheck.unavailable
      : trustedDefinitionId == null
      ? WorkspaceAgentCheck.untrusted
      : trustedDefinitionId != definitionId
      ? WorkspaceAgentCheck.changed
      : WorkspaceAgentCheck.ready;
  bool get verified =>
      observedState == WorkspaceAgentCheck.ready &&
      command.trim().isNotEmpty &&
      definitionId.isNotEmpty &&
      timeoutSeconds > 0;
  Map<String, Object?> get json => {
    'event': event,
    'state': state.name,
    'command': command,
    'definitionId': definitionId,
    'trustedDefinitionId': trustedDefinitionId,
    'timeoutSeconds': timeoutSeconds,
    'matcher': matcher,
  };
}

/// Public observation only. An ID/label is not an association proof.
class WorkspaceAgentSession {
  const WorkspaceAgentSession({
    required this.state,
    required this.totalRequests,
    required this.pendingRequests,
    required this.activeGrants,
    this.id,
    this.label,
  });
  final WorkspaceAgentSessionState state;
  final String? id, label;
  final int totalRequests, pendingRequests, activeGrants;
  bool get valid =>
      [totalRequests, pendingRequests, activeGrants].every((n) => n >= 0) &&
      pendingRequests + activeGrants <= totalRequests &&
      (state == WorkspaceAgentSessionState.linked ||
              state == WorkspaceAgentSessionState.ended
          ? id != null && id!.isNotEmpty
          : id == null && totalRequests == 0) &&
      (state != WorkspaceAgentSessionState.ended ||
          pendingRequests == 0 && activeGrants == 0);
  Map<String, Object?> get json => {
    'state': state.name,
    'id': id,
    'label': label,
    'requests': totalRequests,
    'pending': pendingRequests,
    'grants': activeGrants,
  };
}

class WorkspaceAgentOverview {
  WorkspaceAgentOverview({
    required this.version,
    required this.observedAt,
    required this.serviceAvailable,
    required this.cli,
    required this.skill,
    required Iterable<WorkspaceAgentHook> hooks,
    required this.session,
    this.serviceReason,
  }) : hooks = List.unmodifiable(hooks);
  final int version;
  final DateTime observedAt;
  final bool serviceAvailable;
  final WorkspaceAgentCheck cli, skill;
  final List<WorkspaceAgentHook> hooks;
  final WorkspaceAgentSession session;
  final String? serviceReason;
  static const requiredEvents = ['SessionStart', 'SubagentStart', 'SessionEnd'];
  bool get hooksReady => requiredEvents.every(
    (event) =>
        hooks.where((h) => h.event == event).length == 1 &&
        hooks.singleWhere((h) => h.event == event).verified,
  );
  bool get valid =>
      version > 0 &&
      session.valid &&
      hooks.map((h) => h.event).toSet().length == hooks.length &&
      hooks.every((h) => requiredEvents.contains(h.event));
  WorkspaceAgentConnection get connection => !serviceAvailable
      ? WorkspaceAgentConnection.serviceUnavailable
      : cli != WorkspaceAgentCheck.ready || skill != WorkspaceAgentCheck.ready
      ? WorkspaceAgentConnection.toolsMissing
      : !hooksReady
      ? WorkspaceAgentConnection.hooksUntrusted
      : switch (session.state) {
          WorkspaceAgentSessionState.linked => WorkspaceAgentConnection.ready,
          WorkspaceAgentSessionState.missing =>
            WorkspaceAgentConnection.associationMissing,
          WorkspaceAgentSessionState.mismatch =>
            WorkspaceAgentConnection.associationMismatch,
          WorkspaceAgentSessionState.ended =>
            WorkspaceAgentConnection.sessionEnded,
        };
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'version': version,
            'observedAt': observedAt.toUtc().toIso8601String(),
            'service': serviceAvailable,
            'serviceReason': serviceReason,
            'cli': cli.name,
            'skill': skill.name,
            'hooks': hooks.map((h) => h.json).toList(),
            'session': session.json,
          }),
        ),
      )
      .toString();
}

class WorkspaceAgentSessionDetail {
  WorkspaceAgentSessionDetail({
    required this.overviewFingerprint,
    required this.session,
    required Iterable<WorkspaceApprovalSummary> requests,
  }) : requests = List.unmodifiable(requests);
  final String overviewFingerprint;
  final WorkspaceAgentSession session;
  final List<WorkspaceApprovalSummary> requests;
  bool matches(WorkspaceAgentOverview current) =>
      overviewFingerprint == current.fingerprint &&
      session.valid &&
      jsonEncode(session.json) == jsonEncode(current.session.json) &&
      requests.length == session.totalRequests &&
      requests.every((r) => r.id.isNotEmpty && r.sessionId == session.id) &&
      requests.where((r) => r.state == WorkspaceApprovalState.pending).length ==
          session.pendingRequests &&
      requests
              .where((r) => r.state == WorkspaceApprovalState.approved)
              .length ==
          session.activeGrants &&
      requests.map((r) => r.id).toSet().length == requests.length;
}

/// Read-only observations. No hook trust/configuration mutation, process launch,
/// private association, authentication file or chat transcript crosses this port.
abstract interface class WorkspaceAgentsSource {
  Future<WorkspaceAgentOverview> read();
  Future<WorkspaceAgentOverview> diagnose(int expectedVersion);
  Future<WorkspaceAgentSessionDetail> currentSession(int expectedVersion);
}
