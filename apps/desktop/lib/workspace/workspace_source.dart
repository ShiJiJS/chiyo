/// Frontend-only summaries and failures. No database, authorization proof,
/// secret material or operating-system handle crosses this boundary.
class WorkspaceSummary {
  const WorkspaceSummary({
    required this.records,
    required this.pending,
    required this.proposals,
  });
  const WorkspaceSummary.empty() : records = 0, pending = 0, proposals = 0;
  final int records, pending, proposals;
  bool get isEmpty => records == 0 && pending == 0 && proposals == 0;
}

class WorkspaceFailure implements Exception {
  const WorkspaceFailure(this.code, this.message);
  final String code, message;
}

abstract interface class WorkspaceSource {
  Future<WorkspaceSummary> loadSummary();
}

enum WorkspaceLoad { idle, loading, ready, empty, error }

enum WorkspacePage {
  library('信息库'),
  approvals('访问审批'),
  proposals('录入提案'),
  history('授权历史'),
  settings('设置');

  const WorkspacePage(this.label);
  final String label;
}

/// Identity is separate from display text. Each page can retain its own query,
/// selection and scroll state while another destination is open.
class WorkspaceLocation {
  const WorkspaceLocation(this.page, {this.objectId});
  final WorkspacePage page;
  final String? objectId;
}
