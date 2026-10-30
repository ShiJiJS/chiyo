import 'dart:async';
import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import 'builtin_workspace_definitions.dart';
import 'owner_workspace_classification.dart';
import 'owner_workspace_history.dart';
import 'owner_workspace_grant_history.dart';
import 'owner_workspace_information.dart';
import 'owner_workspace_approvals.dart';
import 'owner_workspace_agents.dart';
import 'unavailable_workspace_sources.dart';
import 'workspace_source.dart';

/// One owner projection of one library. Its caller owns service/repository
/// lifetime and must replace this source after a successful library restore.
/// Unsupported modules fail explicitly instead of showing fictional results.
class OwnerWorkspaceSource implements WorkspaceSource {
  OwnerWorkspaceSource({
    required this.owner,
    Map<String, Map<String, Object?>>? definitions,
    Duration refreshInterval = const Duration(seconds: 1),
    this.settings = const UnavailableWorkspaceSettings(),
    this.backups = const UnavailableWorkspaceBackup(),
    this.runtime = const UnavailableWorkspaceRuntime(),
    WorkspaceAgentsSource? agents,
    this.credentials = const UnavailableWorkspaceCredential(),
    WorkspaceApprovalSource? approvals,
    WorkspaceGrantHistorySource? grantHistory,
    this.proposals = const UnavailableWorkspaceProposal(),
    this.plugins = const UnavailableWorkspacePlugin(),
    this.hosts = const UnavailableWorkspaceHost(),
    this.legacyTemplates = const UnavailableWorkspaceLegacyTemplate(),
  }) : _scope = owner.captureLibraryScope() {
    this.agents = agents ?? OwnerWorkspaceAgents(owner: owner);
    this.approvals = approvals ?? OwnerWorkspaceApprovals(owner: owner);
    this.grantHistory =
        grantHistory ?? OwnerWorkspaceGrantHistory(owner: owner);
    _information = OwnerWorkspaceInformation(
      owner: owner,
      templates: definitions ?? builtinWorkspaceDefinitions,
      onChanged: _changed,
    );
    _classification = OwnerWorkspaceClassification(
      owner: owner,
      information: _information,
      onChanged: () => _changed(null),
    );
    _history = OwnerWorkspaceHistory(
      information: _information,
      onChanged: _changed,
    );
    _requests = owner.requestSubmitted.listen((_) => _changed(null));
    // Older owner/Agent writes have no general change feed. Compare only real
    // metadata, including versions, so edits outside this UI are discoverable.
    if (refreshInterval > Duration.zero) {
      _timer = Timer.periodic(refreshInterval, (_) => refreshFromOwner());
    }
    refreshFromOwner();
  }
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  bool get isCurrentLibrary => !_disposed && _scope.isCurrent;
  late final OwnerWorkspaceInformation _information;
  late final OwnerWorkspaceClassification _classification;
  late final OwnerWorkspaceHistory _history;
  final _changes = StreamController<WorkspaceRecordRef?>.broadcast();
  late final StreamSubscription<String> _requests;
  Timer? _timer;
  bool _disposed = false;
  String? _observed;
  @override
  final WorkspaceSettingsSource settings;
  @override
  final WorkspaceBackupSource backups;
  @override
  final WorkspaceRuntimeSource runtime;
  @override
  late final WorkspaceAgentsSource agents;
  @override
  final WorkspaceCredentialSource credentials;
  @override
  late final WorkspaceApprovalSource approvals;
  @override
  late final WorkspaceGrantHistorySource grantHistory;
  @override
  final WorkspaceProposalSource proposals;
  @override
  final WorkspacePluginSource plugins;
  @override
  final WorkspaceHostSource hosts;
  @override
  final WorkspaceLegacyTemplateSource legacyTemplates;
  @override
  Stream<WorkspaceRecordRef?> get changes => _changes.stream;

  void _changed(WorkspaceRecordRef? ref) {
    if (!_disposed) _changes.add(ref);
  }

  /// Also used after native resume. No body, capability or key is retained in
  /// the observation signature, and it is never written to disk or logs.
  void refreshFromOwner() {
    if (_disposed) return;
    String observed;
    try {
      observed = !isCurrentLibrary
          ? 'library_changed'
          : !owner.serviceAvailable
          ? 'unavailable'
          : jsonEncode([
              [
                for (final i in owner.information) [i.id, i.version],
              ],
              [
                for (final c in owner.credentials)
                  [c.id, c.modifiedAt.toIso8601String()],
              ],
              [
                for (final d in owner.directories) [d.id, d.parentId, d.name],
              ],
              [
                for (final t in owner.tags) [t.id, t.name],
              ],
              [
                for (final r in owner.recycleEntries) [r.id, r.version],
              ],
              [
                for (final r in owner.informationRequests)
                  [
                    r.id,
                    r.state.name,
                    r.sessionEnded,
                    r.decisionPending,
                    r.grantExpiresAt?.toIso8601String(),
                    for (final f in r.approvedFields ?? <core.FieldRef>[])
                      [f.itemId, f.fieldId],
                  ],
              ],
              [
                for (final s in owner.sessions) [s.id, s.chatLabel, s.ended],
              ],
              owner.accessRecordObservation,
              owner.queryProposals(limit: 1).pendingCount,
            ]);
    } on Object {
      observed = 'unavailable';
    }
    if (_observed != observed) {
      _observed = observed;
      _changed(null);
    }
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    if (_disposed) throw const WorkspaceFailure('unavailable', '此资料窗口已关闭。');
    try {
      return await owner.inLibraryScope(_scope, action);
    } on core.AccessFailure catch (e) {
      if (e.status == 'library_changed') {
        throw const WorkspaceFailure(
          'library_changed',
          '资料库已替换，请重新打开资料；旧表单不能提交到新库。',
        );
      }
      rethrow;
    }
  }

  Future<T> _unsupported<T>() async =>
      throw const WorkspaceFailure('unsupported', '此功能的真实数据接入尚未完成。');

  @override
  Future<WorkspaceSummary> loadSummary() => _read(() async {
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务尚未就绪。');
    }
    return WorkspaceSummary(
      records: owner.information.length + owner.credentials.length,
      pending: owner.informationRequests
          .where((r) => r.state == core.AccessRequestState.pending)
          .length,
      proposals: owner.queryProposals(limit: 1).pendingCount,
    );
  });
  @override
  Future<WorkspaceCatalog> loadCatalog() => _read(_classification.loadCatalog);
  @override
  Future<WorkspaceDirectory?> changeDirectory(
    WorkspaceDirectoryChange change,
  ) => _read(() => _classification.changeDirectory(change));
  @override
  Future<WorkspaceClassificationReceipt> changeClassification(
    WorkspaceClassificationChange change,
  ) => _read(() => _classification.changeClassification(change));
  @override
  Future<WorkspaceClassificationReceipt?> classificationOperationReceipt(
    String operationId,
  ) => _read(() => _classification.classificationOperationReceipt(operationId));
  @override
  Future<WorkspaceTagRemovalPreview> previewTagRemoval(String tagId) =>
      _read(() => _classification.previewTagRemoval(tagId));
  @override
  Future<Map<String, Object?>> loadTemplate(String typeId) =>
      _read(() => _information.loadTemplate(typeId));
  @override
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) => _read(
    () => _information.queryRecords(query, keepSelection: keepSelection),
  );
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) =>
      _read(() => _information.readDetail(ref));
  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) => _read(() => _information.queryRelationCandidates(query));
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) => _read(() => _information.readSummaries(refs));
  @override
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) =>
      _read(() => _history.loadRevisions(ref));
  @override
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) => _read(
    () => _history.previewRevision(
      ref,
      version,
      expectedVersion: expectedVersion,
    ),
  );
  @override
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) => _read(
    () =>
        _history.queryRecycled(keyword: keyword, offset: offset, limit: limit),
  );
  @override
  Future<WorkspaceArchive> readRecycled(String entryId) =>
      _read(() => _history.readRecycled(entryId));
  @override
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange change) =>
      _read(() => _history.changeRecord(change));
  @override
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) =>
      _read(() => _information.saveRecord(edit));
  @override
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft) =>
      _read(() => _information.createRecord(draft));

  @override
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(
    String operationId,
  ) => _read(() async {
    // Both stores must be read successfully. Never report confirmed absence
    // after one failed lookup, or guess which result an ambiguous ID meant.
    final saved = await _information.recordOperationReceipt(operationId);
    final changed = await _history.lifecycleOperationReceipt(operationId);
    if (saved != null && changed != null) {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '原操作编号对应多种记录，无法确认结果，请保留现场。',
      );
    }
    return saved ?? changed;
  });

  @override
  Future<WorkspaceAdoptionPreview> previewAdoption(
    WorkspaceAdoptionDraft draft,
  ) => _unsupported();
  @override
  Future<void> releaseAdoption(String planId) => _unsupported();
  @override
  Future<WorkspaceRecordReceipt> applyAdoption(
    String operationId,
    String planId,
  ) => _unsupported();
  @override
  Future<WorkspaceFileHistory> loadFileHistory(
    WorkspaceRecordRef record,
    String fieldKey,
  ) => _unsupported();
  @override
  Future<WorkspaceFilePreview> readFilePreview(
    WorkspaceRecordRef record,
    String fieldKey, {
    int? version,
    int page = 0,
  }) => _unsupported();
  @override
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) =>
      _unsupported();
  @override
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change) =>
      _unsupported();
  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(
    String operationId,
  ) => _unsupported();
  @override
  Future<WorkspaceFileActionResult> fileAction(
    WorkspaceRecordRef record,
    String fieldKey,
    int version,
    WorkspaceFileAction action, {
    required String operationId,
  }) => _unsupported();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    await _requests.cancel();
    await _changes.close();
  }
}
