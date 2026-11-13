import 'workspace_source.dart';

/// User-visible device reports stored by the server, never a claim that this
/// App inspected the reported processes or owns their material on this Mac.
class WorkspaceServerRuntimeObservation {
  WorkspaceServerRuntimeObservation({
    required this.revision,
    required this.materials,
    required this.copies,
    required this.sessions,
    required this.grants,
    required this.pendingRequests,
    required this.unconfirmedProcesses,
    this.programs = const [],
  });
  final String revision;
  final List<WorkspaceApprovalExecution> materials;
  final List<WorkspaceCopyMaintenance> copies;
  final List<WorkspaceRuntimeProgram> programs;
  final int sessions, grants, pendingRequests, unconfirmedProcesses;
}
