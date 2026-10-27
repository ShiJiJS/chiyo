import 'workspace_records.dart';
import 'workspace_history.dart';
import 'workspace_files.dart';
import 'workspace_credentials.dart';
import 'workspace_plugins.dart';
import 'workspace_hosts.dart';
import 'workspace_adoption.dart';
import 'workspace_legacy_templates.dart';
import 'workspace_approvals.dart';
export 'workspace_history.dart';
export 'workspace_records.dart';
export 'workspace_files.dart';
export 'workspace_credentials.dart';
export 'workspace_operation.dart';
export 'workspace_plugins.dart';
export 'workspace_hosts.dart';
export 'workspace_adoption.dart';
export 'workspace_legacy_templates.dart';
export 'workspace_approvals.dart';

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
  WorkspaceCredentialSource get credentials;
  WorkspaceApprovalSource get approvals;
  WorkspacePluginSource get plugins;
  WorkspaceHostSource get hosts;
  WorkspaceLegacyTemplateSource get legacyTemplates;

  /// Invalidates UI projections; null means a reset or a catalog change.
  Stream<WorkspaceRecordRef?> get changes;
  Future<WorkspaceSummary> loadSummary();
  Future<WorkspaceCatalog> loadCatalog();

  /// Returns the created/updated directory, or null after an empty deletion.
  /// Rejections throw WorkspaceFailure and leave classification unchanged.
  Future<WorkspaceDirectory?> changeDirectory(WorkspaceDirectoryChange change);
  Future<Map<String, Object?>> loadTemplate(String typeId);
  Future<WorkspaceAdoptionPreview> previewAdoption(
    WorkspaceAdoptionDraft draft,
  );
  Future<void> releaseAdoption(String planId);
  Future<WorkspaceRecordReceipt> applyAdoption(
    String operationId,
    String planId,
  );
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  });
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref);
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  );

  /// Resolves identities for relation links without loading their field values.
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  );
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref);
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  });
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  });
  Future<WorkspaceArchive> readRecycled(String entryId);
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange change);
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit);
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft);

  /// null means confirmed never committed. Read failures must throw instead.
  /// This returns no content, including after recycle expiry or permanent purge.
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(String operationId);
  Future<WorkspaceFileHistory> loadFileHistory(
    WorkspaceRecordRef record,
    String fieldKey,
  );
  Future<WorkspaceFilePreview> readFilePreview(
    WorkspaceRecordRef record,
    String fieldKey, {
    int? version,
    int page = 0,
  });
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input);
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change);
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(
    String operationId,
  );
  Future<WorkspaceFileActionResult> fileAction(
    WorkspaceRecordRef record,
    String fieldKey,
    int version,
    WorkspaceFileAction action, {
    required String operationId,
  });
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
