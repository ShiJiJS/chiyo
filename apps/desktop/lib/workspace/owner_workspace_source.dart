import 'owner_workspace_file_opens.dart';
import 'owner_file_open_dispatcher.dart';
import 'package:info_storage/info_storage.dart';
import '../backups.dart';
import 'owner_workspace_file_actions.dart';
import 'dart:async';
import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import 'builtin_workspace_definitions.dart';
import 'owner_workspace_classification.dart';
import 'owner_workspace_history.dart';
import 'owner_workspace_grant_history.dart';
import 'owner_workspace_information.dart';
import 'owner_workspace_files.dart';
import 'owner_workspace_file_selections.dart';
import 'owner_workspace_file_changes.dart';
import 'owner_pdf_preview.dart';
import 'owner_workspace_approvals.dart';
import 'owner_workspace_agents.dart';
import 'unavailable_workspace_sources.dart';
import 'workspace_source.dart';

/// One owner projection of one library. Its caller owns service/repository
/// lifetime and must replace this source after a successful library restore.
/// Unsupported modules fail explicitly instead of showing fictional results.
class OwnerWorkspaceSource
    implements
        WorkspaceSource,
        WorkspaceFileSelectionReleaser,
        WorkspaceFileActionRecovery,
        WorkspaceFileOpenRecovery {
  OwnerWorkspaceSource({
    required this.owner,
    InformationFileOutputs? fileOutputs,
    InformationFileOpens? fileOpens,
    OwnerFileOpenDispatcher openDispatcher =
        const NativeOwnerFileOpenDispatcher(),
    BackupFilePicker outputPicker = const NativeBackupFilePicker(),
    OwnerPdfPreviewRenderer pdfPreview = const NativeOwnerPdfPreview(),
    OwnerWorkspaceFileSelections? fileSelections,
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
        grantHistory ??
        OwnerWorkspaceGrantHistory(owner: owner, pdfPreview: pdfPreview);
    _information = OwnerWorkspaceInformation(
      owner: owner,
      templates: definitions ?? builtinWorkspaceDefinitions,
      onChanged: _changed,
    );
    _files = OwnerWorkspaceFiles(owner, _information, pdf: pdfPreview);
    _fileActions = fileOutputs == null
        ? null
        : OwnerWorkspaceFileActions(
            owner,
            _information,
            _files,
            fileOutputs,
            outputPicker,
            opens: fileOpens,
          );
    _fileOpens = fileOpens == null
        ? null
        : OwnerWorkspaceFileOpens(
            owner,
            _information,
            _files,
            fileOpens,
            openDispatcher,
            outputs: fileOutputs,
          );
    selections = fileSelections ?? OwnerWorkspaceFileSelections(owner);
    _fileChanges = OwnerWorkspaceFileChanges(
      owner,
      _information,
      selections,
      _changed,
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
  late final OwnerWorkspaceFiles _files;
  late final OwnerWorkspaceFileActions? _fileActions;
  late final OwnerWorkspaceFileOpens? _fileOpens;
  late final OwnerWorkspaceFileSelections selections;
  late final OwnerWorkspaceFileChanges _fileChanges;
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
              [
                for (final d in owner.informationFileDeliveries)
                  [
                    d.id,
                    d.state,
                    d.targetState,
                    d.reason,
                    d.cleanupError,
                    d.holdsCopy,
                    d.restoredAt?.toIso8601String(),
                  ],
              ],
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
  ) => _read(() => _files.history(record, fieldKey));
  @override
  Future<WorkspaceFilePreview> readFilePreview(
    WorkspaceRecordRef record,
    String fieldKey, {
    int? version,
    int page = 0,
  }) => _read(
    () => _files.preview(record, fieldKey, version: version, page: page),
  );
  @override
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) =>
      _read(() => _fileChanges.importFile(input));
  @override
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change) =>
      _read(() => _fileChanges.change(change));
  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(
    String operationId,
  ) => _read(() async {
    final mutation = await _fileChanges.receipt(operationId);
    final output = await _fileActions?.receipt(operationId);
    final opened = await _fileOpens?.receipt(operationId);
    if ([
          mutation,
          output,
          opened,
        ].whereType<WorkspaceFileOperationReceipt>().length >
        1) {
      throw const WorkspaceFailure('unknown_outcome', '操作编号对应多种结果，无法确认。');
    }
    return opened ?? output ?? mutation;
  });
  @override
  Future<WorkspaceFileActionResult> fileAction(
    WorkspaceRecordRef record,
    String fieldKey,
    int version,
    WorkspaceFileAction action, {
    required String operationId,
  }) => _read(() async {
    if (await _fileChanges.receipt(operationId) != null) {
      throw const WorkspaceFailure('operation_conflict', '此编号已用于文件更改。');
    }
    final pending = (await fileActionState(record, fieldKey)).pending;
    if (pending != null && pending.operationId != operationId) {
      throw const WorkspaceFailure('previous_pending', '原文件操作尚未确认，已切回原操作供你核对。');
    }
    if (action == WorkspaceFileAction.open) {
      if (_fileOpens == null) return _unsupported();
      if (await _fileActions?.receipt(operationId) != null) {
        throw const WorkspaceFailure('operation_conflict', '此编号已用于另存。');
      }
      return _fileOpens.open(record, fieldKey, version, operationId);
    }
    if (_fileActions == null) return _unsupported();
    if (await _fileOpens?.receipt(operationId) != null) {
      throw const WorkspaceFailure('operation_conflict', '此编号已用于打开。');
    }
    return _fileActions.save(record, fieldKey, version, operationId);
  });

  @override
  Future<WorkspaceFileActionState> fileActionState(
    WorkspaceRecordRef record,
    String key,
  ) => _read(() async {
    final saved =
        await _fileActions?.state(record, key) ??
        const WorkspaceFileActionState();
    final opened =
        await _fileOpens?.state(record, key) ??
        const WorkspaceFileActionState();
    if (saved.pending != null && opened.pending != null) {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '存在多种未确认文件操作，请先结束使用并清理临时副本。',
      );
    }
    return WorkspaceFileActionState(
      pending: saved.pending ?? opened.pending,
      cleanupPending: saved.cleanupPending,
      openCopies: opened.openCopies,
      openCleanupPending: opened.openCleanupPending,
    );
  });
  @override
  Future<void> recoverFileActionAccess(String id) => _read(() async {
    await _fileActions?.recoverAccess(id);
  });
  @override
  Future<void> cleanupFileActions(WorkspaceRecordRef record, String key) =>
      _read(() async {
        await _fileActions?.cleanup(record, key);
      });
  @override
  Future<void> finishFileOpen(String id) => _read(() async {
    await _fileOpens?.finish(id);
  });
  @override
  Future<void> closeOpenFileCopies(WorkspaceRecordRef record, String key) =>
      _read(() async {
        await _fileOpens?.closeCopies(record, key);
      });

  @override
  Future<void> releaseFileSelection(String id) => selections.release(id);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _fileActions?.dispose();
    _fileOpens?.dispose();
    _timer?.cancel();
    await selections.dispose();
    await _requests.cancel();
    await _changes.close();
  }
}
