import 'workspace_records.dart';
export 'workspace_records.dart';

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

abstract interface class WorkspaceSource {
  /// Invalidates UI projections; null means a reset or a catalog change.
  Stream<WorkspaceRecordRef?> get changes;
  Future<WorkspaceSummary> loadSummary();
  Future<WorkspaceCatalog> loadCatalog();
  Future<Map<String, Object?>> loadTemplate(String typeId);
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  });
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref);

  /// Resolves identities for relation links without loading their field values.
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  );
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit);
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft);
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
  const WorkspaceLocation(
    this.page, {
    this.objectId,
    this.query,
    this.scrollOffset = 0,
  });
  final WorkspacePage page;
  final String? objectId;
  final WorkspaceQuery? query;
  final double scrollOffset;
}
