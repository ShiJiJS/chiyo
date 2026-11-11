import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_approvals.dart';
import 'approval_transport.dart' show approvalSummaryToJson;

/// Management-only metadata. Public session identifiers are observations, never
/// association proofs, session secrets, end capabilities or content grants.
// Runtime counters still need live/ended session facts. Setup diagnostics and
// hook/trust UI models have been removed; these facts confer no authority.
enum WorkspaceAgentSessionState { linked, ended }

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
      id != null &&
      id!.isNotEmpty &&
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

class WorkspaceAgentSessions {
  WorkspaceAgentSessions({
    required this.revision,
    required this.serviceAvailable,
    required Iterable<WorkspaceAgentSession> sessions,
    required Iterable<WorkspaceApprovalSummary> requests,
  }) : sessions = List.unmodifiable(sessions),
       requests = List.unmodifiable(requests);
  final String revision;
  final bool serviceAvailable;
  final List<WorkspaceAgentSession> sessions;
  final List<WorkspaceApprovalSummary> requests;
  bool get valid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(revision) &&
      sessions.every((s) => s.valid && s.id != null) &&
      sessions.map((s) => s.id).toSet().length == sessions.length &&
      requests.map((r) => r.id).toSet().length == requests.length &&
      requests.every((r) => sessions.any((s) => s.id == r.sessionId)) &&
      sessions.every((s) {
        final rows = requests.where((r) => r.sessionId == s.id);
        return s.totalRequests == rows.length &&
            s.pendingRequests ==
                (s.state == WorkspaceAgentSessionState.ended
                    ? 0
                    : rows
                          .where(
                            (r) => r.state == WorkspaceApprovalState.pending,
                          )
                          .length) &&
            s.activeGrants ==
                (s.state == WorkspaceAgentSessionState.ended
                    ? 0
                    : rows
                          .where(
                            (r) => r.state == WorkspaceApprovalState.approved,
                          )
                          .length);
      });
}

String agentSessionsRevision(
  String scope,
  bool available,
  Iterable<WorkspaceAgentSession> sessions,
  Iterable<WorkspaceApprovalSummary> requests,
) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          scope,
          available,
          sessions.map((s) => s.json).toList(),
          requests.map(approvalSummaryToJson).toList(),
        ]),
      ),
    )
    .toString();
