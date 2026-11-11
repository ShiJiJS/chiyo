import 'workspace_source.dart';

// Explicit unavailable boundaries for modules not yet connected to this UI.
// In particular, failed receipt lookup is never reported as confirmed absence.
Future<T> _unavailable<T>() =>
    Future<T>.error(const WorkspaceFailure('unsupported', '此功能的真实数据接入尚未完成。'));

class UnavailableWorkspaceSettings implements WorkspaceSettingsSource {
  const UnavailableWorkspaceSettings();
  @override
  Future<WorkspacePreferences> read() => _unavailable();
  @override
  Future<WorkspaceSettingsReceipt> change(WorkspaceSettingsChange change) =>
      _unavailable();
  @override
  Future<WorkspaceSettingsReceipt?> receipt(String operationId) =>
      _unavailable();
  @override
  Future<WorkspaceNotificationPreview> notificationPreview() => _unavailable();
  @override
  Future<WorkspaceRetentionPreview> previewRetention(int days) =>
      _unavailable();
}

class UnavailableWorkspaceBackup implements WorkspaceBackupSource {
  const UnavailableWorkspaceBackup();
  @override
  Future<WorkspaceBackupStatus> status() => _unavailable();
  @override
  Future<String> revealRecoveryKey() => _unavailable();
  @override
  Future<WorkspaceBackupPreview> inspect(
    WorkspaceBackupResource archive,
    WorkspaceBackupResource key,
  ) => _unavailable();
  @override
  Future<void> releasePreview(String token) => _unavailable();
  @override
  Future<WorkspaceBackupReceipt> change(WorkspaceBackupChange change) =>
      _unavailable();
  @override
  Future<WorkspaceBackupReceipt?> receipt(String operationId) => _unavailable();
}

class UnavailableWorkspaceRuntime implements WorkspaceRuntimeSource {
  const UnavailableWorkspaceRuntime();
  @override
  Future<WorkspaceRuntimeStatus> status() => _unavailable();
  @override
  Future<WorkspaceQuitPreview> previewQuit() => _unavailable();
  @override
  Future<void> releaseQuit(String token) => _unavailable();
  @override
  Future<WorkspaceRuntimeReceipt> change(WorkspaceRuntimeChange change) =>
      _unavailable();
  @override
  Future<WorkspaceRuntimeReceipt?> receipt(String operationId) =>
      _unavailable();
}

class UnavailableWorkspaceCredential implements WorkspaceCredentialSource {
  const UnavailableWorkspaceCredential();
  @override
  Future<WorkspaceCredentialDetail> read(WorkspaceRecordRef ref) =>
      _unavailable();
  @override
  Future<WorkspaceCredentialMaterialHistory> materials(
    WorkspaceRecordRef ref,
  ) => _unavailable();
  @override
  Future<WorkspaceCredentialRecycled> readRecycled(String entryId) =>
      _unavailable();
  @override
  Future<WorkspaceCredentialReceipt> change(WorkspaceCredentialChange change) =>
      _unavailable();
  @override
  Future<List<WorkspaceCredentialCandidate>> candidates() => _unavailable();
  @override
  Future<void> releaseCandidate(String candidateId) => _unavailable();
  @override
  Future<WorkspaceCredentialReceipt> save(WorkspaceCredentialWrite write) =>
      _unavailable();
  @override
  Future<WorkspaceCredentialReceipt> setEnabled(
    WorkspaceCredentialToggle change,
  ) => _unavailable();
  @override
  Future<WorkspaceCredentialReceipt?> receipt(String operationId) =>
      _unavailable();
  @override
  Future<List<WorkspaceCredentialSession>> sessions() => _unavailable();
  @override
  Future<List<WorkspaceCredentialReceiver>> receivers(WorkspaceRecordRef ref) =>
      _unavailable();
  @override
  Future<WorkspaceCredentialReceipt> requestUse(
    WorkspaceCredentialUseDraft draft,
  ) => _unavailable();
  @override
  Future<List<WorkspaceCredentialUseRequest>> requests({
    WorkspaceRecordRef? ref,
  }) => _unavailable();
  @override
  Future<List<WorkspaceCredentialUseHistory>> history(WorkspaceRecordRef ref) =>
      _unavailable();
}

class UnavailableWorkspaceApproval implements WorkspaceApprovalSource {
  const UnavailableWorkspaceApproval();
  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery query, {
    String? keepSelection,
  }) => _unavailable();
  @override
  Future<WorkspaceApprovalDetail> read(String id) => _unavailable();
  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange change) =>
      _unavailable();
  @override
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) => _unavailable();
  @override
  Future<WorkspaceApprovalReceipt?> receipt(String operationId) =>
      _unavailable();
}

class UnavailableWorkspaceGrantHistory implements WorkspaceGrantHistorySource {
  const UnavailableWorkspaceGrantHistory();
  @override
  Future<WorkspaceGrantResults> query(
    WorkspaceGrantQuery query, {
    String? keepSelection,
  }) => _unavailable();
  @override
  Future<WorkspaceGrantDetail> read(String id) => _unavailable();
  @override
  Future<WorkspaceFilePreview> filePreview(
    String historyId,
    String scopeId, {
    int page = 0,
  }) => _unavailable();
  @override
  Future<WorkspaceArchive> snapshot(
    String historyId,
    WorkspaceRecordRef record,
  ) => _unavailable();
}

class UnavailableWorkspaceProposal implements WorkspaceProposalSource {
  const UnavailableWorkspaceProposal();
  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery query, {
    String? keepSelection,
  }) => _unavailable();
  @override
  Future<WorkspaceProposalDetail> read(String id) => _unavailable();
  @override
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange change) =>
      _unavailable();
  @override
  Future<WorkspaceProposalReceipt?> receipt(String operationId) =>
      _unavailable();
  @override
  WorkspaceRelationSource relations(
    String proposalId,
    String itemId,
    int version,
  ) => throw const WorkspaceFailure('unsupported', '提案的真实数据接入尚未完成。');
  @override
  Future<WorkspaceCatalog> catalog() => _unavailable();
  @override
  Future<WorkspaceArchive> snapshot(
    String proposalId,
    WorkspaceRecordRef record,
  ) => _unavailable();
  @override
  Future<WorkspaceDetail> currentTarget(String proposalId) => _unavailable();
}

class UnavailableWorkspacePlugin implements WorkspacePluginSource {
  const UnavailableWorkspacePlugin();
  @override
  Future<WorkspacePluginCatalog> load() => _unavailable();
  @override
  Future<WorkspacePluginCandidate> prepareUpdate(
    WorkspacePluginUpdate update,
    int catalogVersion,
  ) => _unavailable();
  @override
  Future<WorkspacePluginPreview> previewInstall(String selectionId) =>
      _unavailable();
  @override
  Future<void> releaseCandidate(String selectionId) => _unavailable();
  @override
  Future<WorkspacePluginReceipt> change(WorkspacePluginChange change) =>
      _unavailable();
  @override
  Future<WorkspacePluginReceipt?> receipt(String operationId) => _unavailable();
}

class UnavailableWorkspaceHost implements WorkspaceHostSource {
  const UnavailableWorkspaceHost();
  @override
  Future<WorkspaceHostImportStatus?> importedFile() => _unavailable();
  @override
  Future<WorkspaceHostImportPreview> previewImport(String selectionId) =>
      _unavailable();
  @override
  Future<WorkspaceHostImportReceipt> importFile(
    WorkspaceHostImportChange change,
  ) => _unavailable();
  @override
  Future<WorkspaceHostImportReceipt?> importReceipt(String operationId) =>
      _unavailable();
  @override
  Future<void> releaseImport(String selectionId) => _unavailable();
  @override
  Future<List<WorkspaceHostIdentity>> load() => _unavailable();
  @override
  Future<WorkspaceHostIdentity> read(WorkspaceHostTarget target) =>
      _unavailable();
  @override
  Future<WorkspaceHostReceipt> change(WorkspaceHostChange change) =>
      _unavailable();
  @override
  Future<WorkspaceHostReceipt?> receipt(String operationId) => _unavailable();
}

class UnavailableWorkspaceLegacyTemplate
    implements WorkspaceLegacyTemplateSource {
  const UnavailableWorkspaceLegacyTemplate();
  @override
  Future<List<WorkspaceLegacyTemplate>> load() => _unavailable();
  @override
  Future<WorkspaceLegacyTemplate> read(String id) => _unavailable();
}

/// Explicit typed boundaries while a remote module is being connected.
/// Unsupported reads never masquerade as empty successful results.
class UnavailableWorkspaceSource implements WorkspaceSource {
  @override
  WorkspaceSettingsSource get settings => const UnavailableWorkspaceSettings();
  @override
  WorkspaceBackupSource get backups => const UnavailableWorkspaceBackup();
  @override
  WorkspaceRuntimeSource get runtime => const UnavailableWorkspaceRuntime();
  @override
  WorkspaceCredentialSource get credentials =>
      const UnavailableWorkspaceCredential();
  @override
  WorkspaceApprovalSource get approvals => const UnavailableWorkspaceApproval();
  @override
  WorkspaceGrantHistorySource get grantHistory =>
      const UnavailableWorkspaceGrantHistory();
  @override
  WorkspaceProposalSource get proposals => const UnavailableWorkspaceProposal();
  @override
  WorkspacePluginSource get plugins => const UnavailableWorkspacePlugin();
  @override
  WorkspaceHostSource get hosts => const UnavailableWorkspaceHost();
  @override
  WorkspaceLegacyTemplateSource get legacyTemplates =>
      const UnavailableWorkspaceLegacyTemplate();
  @override
  Stream<WorkspaceRecordRef?> get changes => const Stream.empty();
  @override
  Future<WorkspaceSummary> loadSummary() => _unavailable();
  @override
  Future<WorkspaceCatalog> loadCatalog() => _unavailable();
  @override
  Future<WorkspaceDirectory?> changeDirectory(
    WorkspaceDirectoryChange change,
  ) => _unavailable();
  @override
  Future<WorkspaceClassificationReceipt> changeClassification(
    WorkspaceClassificationChange change,
  ) => _unavailable();
  @override
  Future<WorkspaceClassificationReceipt?> classificationOperationReceipt(
    String operationId,
  ) => _unavailable();
  @override
  Future<WorkspaceTagRemovalPreview> previewTagRemoval(String tagId) =>
      _unavailable();
  @override
  Future<Map<String, Object?>> loadTemplate(String typeId) => _unavailable();
  @override
  Future<WorkspaceAdoptionPreview> previewAdoption(
    WorkspaceAdoptionDraft draft,
  ) => _unavailable();
  @override
  Future<void> releaseAdoption(String planId) => _unavailable();
  @override
  Future<WorkspaceRecordReceipt> applyAdoption(
    String operationId,
    String planId,
  ) => _unavailable();
  @override
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) => _unavailable();
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) => _unavailable();
  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) => _unavailable();
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) => _unavailable();
  @override
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) =>
      _unavailable();
  @override
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
    String? snapshotId,
  }) => _unavailable();
  @override
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) => _unavailable();
  @override
  Future<WorkspaceArchive> readRecycled(String entryId) => _unavailable();
  @override
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange change) =>
      _unavailable();
  @override
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) => _unavailable();
  @override
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft) =>
      _unavailable();
  @override
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(
    String operationId,
  ) => _unavailable();
  @override
  Future<WorkspaceFileHistory> loadFileHistory(
    WorkspaceRecordRef record,
    String fieldKey,
  ) => _unavailable();
  @override
  Future<WorkspaceFilePreview> readFilePreview(
    WorkspaceRecordRef record,
    String fieldKey, {
    int? version,
    WorkspaceFileRef? exact,
    int page = 0,
  }) => _unavailable();
  @override
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) =>
      _unavailable();
  @override
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change) =>
      _unavailable();
  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(
    String operationId,
  ) => _unavailable();
  @override
  Future<WorkspaceFileActionResult> fileAction(
    WorkspaceRecordRef record,
    String fieldKey,
    int version,
    WorkspaceFileAction action, {
    required String operationId,
  }) => _unavailable();
}
