import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/owner_agent_sessions.dart';
import 'workspace_agent_observations.dart';

/// Local compatibility uses the same service projection and package observer.
class OwnerWorkspaceAgents extends WorkspaceAgentObservations {
  OwnerWorkspaceAgents({required core.OwnerAccess owner, super.readBundle})
    : super(readSessions: OwnerAgentSessions(owner).read);
}
