import 'package:info_core/info_core.dart' as core;
import 'agent_sessions.dart';
import 'owner_workspace_approvals.dart';
import 'owner_workspace_additional_approvals.dart';
import 'workspace_agents.dart';
import 'workspace_approvals.dart';
import 'workspace_source.dart' show workspaceOperationId, WorkspaceFailure;

/// The original session/request projection shared by the local and online App.
/// A restore invalidates this observer; no old association becomes a grant.
class OwnerAgentSessions {
  OwnerAgentSessions(this.owner)
    : _scope = owner.captureLibraryScope(),
      _identity = workspaceOperationId();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  final String _identity;
  Future<WorkspaceAgentSessions> read() async {
    try {
      return await owner.inLibraryScope(_scope, () async {
        final available = owner.serviceAvailable;
        final credentialIds = available
            ? owner.credentialUseRequests.map((r) => r.id).toSet()
            : <String>{};
        final requests = available
            ? <WorkspaceApprovalSummary>[
                for (final r in await owner.informationRequestInbox())
                  if (!credentialIds.contains(r.id))
                    OwnerWorkspaceApprovals.summaryOf(r),
                ...OwnerWorkspaceAdditionalApprovals(owner).summaries(),
              ]
            : <WorkspaceApprovalSummary>[];
        final live = available ? owner.sessions : <core.OwnerSessionSnapshot>[];
        final ids = {
          ...live.map((s) => s.id),
          ...requests.map((r) => r.sessionId),
        };
        final sessions = <WorkspaceAgentSession>[];
        for (final id in ids) {
          final association = live.where((s) => s.id == id).firstOrNull;
          final rows = requests.where((r) => r.sessionId == id).toList();
          final ended = association == null || association.ended;
          sessions.add(
            WorkspaceAgentSession(
              state: ended
                  ? WorkspaceAgentSessionState.ended
                  : WorkspaceAgentSessionState.linked,
              id: id,
              label: association?.chatLabel ?? rows.first.chatClaim,
              totalRequests: rows.length,
              pendingRequests: ended
                  ? 0
                  : rows
                        .where((r) => r.state == WorkspaceApprovalState.pending)
                        .length,
              activeGrants: ended
                  ? 0
                  : rows
                        .where(
                          (r) => r.state == WorkspaceApprovalState.approved,
                        )
                        .length,
            ),
          );
        }
        sessions.sort((a, b) => a.id!.compareTo(b.id!));
        requests.sort((a, b) {
          final time = b.submittedAt.compareTo(a.submittedAt);
          return time != 0 ? time : a.id.compareTo(b.id);
        });
        return WorkspaceAgentSessions(
          revision: agentSessionsRevision(
            _identity,
            available,
            sessions,
            requests,
          ),
          serviceAvailable: available,
          sessions: sessions,
          requests: requests,
        );
      });
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, '会话观察暂时不可用，请重新检测。');
    }
  }
}
