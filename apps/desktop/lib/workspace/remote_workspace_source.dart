import 'remote_library_cache.dart';
import 'dart:async';
import 'dart:convert';
import 'package:info_workspace/form_transport.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_remote/owner_client.dart';
import 'workspace_source.dart';
import 'workspace_information_codec.dart';
import 'workspace_order.dart';
import 'unavailable_workspace_sources.dart';
import 'remote_workspace_approvals.dart';
import 'remote_workspace_plugins.dart';
import 'remote_workspace_proposals.dart';
import 'remote_workspace_relations.dart';
import 'remote_workspace_library.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'directory_tree.dart';
import 'remote_workspace_files.dart';
import 'remote_workspace_legacy_templates.dart';
import 'remote_workspace_credentials.dart';
import 'owner_proposal_password_input.dart';
import 'package:info_workspace/credential_transport.dart';
import '../information_files.dart';
import '../backups.dart';
import 'package:info_storage/info_storage.dart';
import 'owner_file_open_dispatcher.dart';
import 'remote_workspace_file_actions.dart';
import 'remote_workspace_hosts.dart';
import 'remote_workspace_history.dart';
import 'remote_workspace_backups.dart';
import 'remote_workspace_settings.dart';
import 'remote_workspace_runtime.dart';
import '../online_desktop_runtime.dart';
import 'package:info_workspace/adoption_transport.dart';

/// Live projections through the existing UI seam; no local library or body
/// cache. Shared codecs preserve the exact ordinary owner display/edit rules.
class RemoteWorkspaceSource
    implements
        WorkspaceSource,
        WorkspaceRecycledFiles,
        WorkspaceLibraryNotifications,
        WorkspaceStorageLocation,
        WorkspaceLibraryMove,
        WorkspaceLibraryRecycle,
        WorkspaceFileSelectionReleaser,
        WorkspaceFileActionRecovery,
        WorkspaceFileOpenRecovery {
  RemoteWorkspaceSource(
    this.client, {
    InformationFilePicker? filePicker,
    this.deviceFilesDirectory,
    this.onNotificationEnable,
    this.onClosing,
    this.desktopRuntime,
    this.outputPicker = const NativeBackupFilePicker(),
    this.openDispatcher = const NativeOwnerFileOpenDispatcher(),
  }) : _observation = client.initialWorkspaceObservation {
    files = RemoteWorkspaceFiles(
      client,
      changed: notifyConnectionChanged,
      picker: filePicker ?? const NativeInformationFilePicker(),
    );
    hosts = RemoteWorkspaceHosts(
      client,
      changed: notifyConnectionChanged,
      picker: filePicker ?? const NativeInformationFilePicker(),
    );
  }
  final OwnerClient client;
  late final cache = RemoteLibraryCache(client, () {
    if (!_libraryChanges.isClosed) _libraryChanges.add(null);
  });
  final _libraryChanges = StreamController<WorkspaceRecordRef?>.broadcast();
  @override
  Stream<WorkspaceRecordRef?> get libraryChanges => _libraryChanges.stream;
  final OnlineDesktopRuntime? desktopRuntime;
  @override
  late final WorkspaceRuntimeSource runtime = desktopRuntime == null
      ? const UnavailableWorkspaceRuntime()
      : RemoteWorkspaceRuntime(
          client,
          desktopRuntime!,
          directory: deviceFilesDirectory,
          copies: _fileActions.runtimeCopies,
          preferences: settings.read,
          changed: notifyConnectionChanged,
        );
  @override
  late final RemoteWorkspaceSettings settings = RemoteWorkspaceSettings(
    client,
    directory: deviceFilesDirectory,
    changed: notifyConnectionChanged,
    onNotificationEnable: onNotificationEnable,
  );
  @override
  late final RemoteWorkspaceBackups backups = RemoteWorkspaceBackups(
    client,
    directory: deviceFilesDirectory,
    changed: notifyConnectionChanged,
    picker: outputPicker,
  );
  late final _history = RemoteWorkspaceHistory(
    client,
    changed: notifyConnectionChanged,
  );
  @override
  late final WorkspaceGrantHistorySource grantHistory =
      RemoteWorkspaceGrantHistory(client);
  @override
  bool get libraryRecycleSupported => _history.libraryRecycleSupported;
  @override
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycle(
    WorkspaceLibrarySelection selection,
  ) => _history.previewLibraryRecycle(selection);
  @override
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycleRestore(
    String id,
    WorkspaceLibraryRestoreOptions options,
  ) => _history.previewLibraryRecycleRestore(id, options);
  @override
  Future<WorkspaceLibraryRecycleReceipt> changeLibraryRecycle(
    WorkspaceLibraryRecycleCommand command,
  ) => _history.changeLibraryRecycle(command);
  @override
  Future<WorkspaceLibraryRecycleReceipt?> libraryRecycleOperationReceipt(
    String id,
  ) => _history.libraryRecycleOperationReceipt(id);
  @override
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) =>
      _history.loadRevisions(ref);
  @override
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) =>
      _history.previewRevision(ref, version, expectedVersion: expectedVersion);
  @override
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) => _history.queryRecycled(keyword: keyword, offset: offset, limit: limit);
  @override
  Future<WorkspaceArchive> readRecycled(String entryId) =>
      _history.readRecycled(entryId);
  @override
  Future<WorkspaceFilePreview> readRecycledFilePreview(
    String entryId,
    String fieldKey, {
    int page = 0,
  }) => _history.readRecycledFilePreview(entryId, fieldKey, page: page);
  @override
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange change) =>
      _history.changeRecord(change);

  @override
  late final RemoteWorkspaceHosts hosts;
  @override
  late final RemoteWorkspaceCredentials credentials =
      RemoteWorkspaceCredentials(client, changed: notifyConnectionChanged);
  late final OwnerProposalPasswords proposalPasswords =
      OwnerProposalPasswords.remote(client);
  final String? deviceFilesDirectory;
  final Future<void> Function()? onNotificationEnable;
  final Future<void> Function(RemoteWorkspaceSource)? onClosing;
  final BackupFilePicker outputPicker;
  final OwnerFileOpenDispatcher openDispatcher;
  late final _fileActions = RemoteWorkspaceFileActions(
    client,
    files,
    readDetail,
    directory: deviceFilesDirectory,
    picker: outputPicker,
    dispatcher: openDispatcher,
  );
  late final RemoteWorkspaceFiles files;
  @override
  late final WorkspaceLegacyTemplateSource legacyTemplates =
      RemoteWorkspaceLegacyTemplates(client);
  @override
  Future<void> releaseFileSelection(String id) => files.release(id);
  @override
  Future<WorkspaceFileHistory> loadFileHistory(
    WorkspaceRecordRef record,
    String fieldKey,
  ) => files.history(record, fieldKey);
  @override
  Future<WorkspaceFilePreview> readFilePreview(
    WorkspaceRecordRef record,
    String fieldKey, {
    int? version,
    int page = 0,
  }) => files.preview(record, fieldKey, version: version, page: page);
  @override
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) =>
      files.importFile(input);
  @override
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change) =>
      files.change(change);
  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(
    String operationId,
  ) async {
    final mutation = await files.receipt(operationId);
    final local = deviceFilesDirectory == null
        ? null
        : await _fileActions.receipt(operationId);
    if (mutation != null && local != null) {
      throw const WorkspaceFailure('unknown_outcome', '操作编号对应多种结果，无法确认。');
    }
    if (mutation != null) await _refreshResolvedRecord(mutation.record);
    return local ?? mutation;
  }

  @override
  Future<WorkspaceFileActionResult> fileAction(
    WorkspaceRecordRef record,
    String fieldKey,
    int version,
    WorkspaceFileAction action, {
    required String operationId,
  }) => _fileActions.action(record, fieldKey, version, action, operationId);
  @override
  Future<WorkspaceFileActionState> fileActionState(
    WorkspaceRecordRef record,
    String fieldKey,
  ) => _fileActions.state(record, fieldKey);
  @override
  Future<void> recoverFileActionAccess(String operationId) =>
      _fileActions.recoverAccess(operationId);
  @override
  Future<void> cleanupFileActions(WorkspaceRecordRef record, String fieldKey) =>
      _fileActions.cleanup(record, fieldKey);
  @override
  Future<void> finishFileOpen(String operationId) =>
      _fileActions.finish(operationId);

  /// Automatic maintenance concerns only this App's registered temporary
  /// files. CLI journals and worker lifetimes belong to their own executors.
  Future<bool> maintainOwnerFiles() async {
    final before = await _fileActions.runtimeCopies();
    final after = await _fileActions.runtimeCopies(maintain: true);
    return jsonEncode(before.map((c) => c.json).toList()) !=
        jsonEncode(after.map((c) => c.json).toList());
  }

  @override
  Future<void> closeOpenFileCopies(
    WorkspaceRecordRef record,
    String fieldKey,
  ) => _fileActions.closeCopies(record, fieldKey);
  late final _library = RemoteWorkspaceLibrary(
    client,
    changed: notifyConnectionChanged,
  );
  @override
  bool get libraryMoveSupported => _library.libraryMoveSupported;
  @override
  bool get libraryOrderSupported => _library.libraryOrderSupported;
  @override
  WorkspaceSort? get preferredLibrarySort => _library.preferredLibrarySort;
  @override
  Future<void> saveLibrarySort(WorkspaceSort sort) =>
      _library.saveLibrarySort(sort);
  @override
  Future<WorkspaceClassificationReceipt> changeClassification(
    WorkspaceClassificationChange change,
  ) => _library.changeClassification(change);
  @override
  Future<WorkspaceDirectory?> changeDirectory(
    WorkspaceDirectoryChange change,
  ) async => (await changeClassification(change)).directory;
  @override
  Future<WorkspaceClassificationReceipt?> classificationOperationReceipt(
    String operationId,
  ) => _library.classificationReceipt(operationId);
  @override
  Future<WorkspaceTagRemovalPreview> previewTagRemoval(String tagId) =>
      _library.previewTagRemoval(tagId);
  @override
  Future<List<WorkspaceLibraryPlacementTarget>> libraryPlacementTargets(
    WorkspaceLibrarySelection selection,
  ) => _library.libraryPlacementTargets(selection);
  @override
  Future<WorkspaceLibraryMovePreview> previewLibraryMove(
    WorkspaceLibrarySelection selection,
    String? targetId, {
    WorkspaceLibraryPosition? position,
  }) => _library.previewLibraryMove(selection, targetId, position: position);
  @override
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  ) => _library.moveLibrarySelection(command);
  @override
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(String id) =>
      _library.libraryMoveOperationReceipt(id);
  @override
  late final WorkspaceProposalSource proposals = RemoteWorkspaceProposals(
    client,
    changed: notifyConnectionChanged,
  );
  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) => RemoteWorkspaceRelations(client).queryRelationCandidates(query);
  @override
  late final RemoteWorkspacePlugins plugins = RemoteWorkspacePlugins(
    client,
    cached: () async {
      if (_mutationGeneration != _refreshedMutation) await _refreshMutations();
      final raw = cache.resources?['plugins'];
      return raw == null ? null : Map<String, dynamic>.from(raw as Map);
    },
    changed: notifyConnectionChanged,
  );
  @override
  late final WorkspaceApprovalSource approvals = RemoteWorkspaceApprovals(
    client,
    onChanged: notifyConnectionChanged,
  );
  String? _observation;
  Map<String, dynamic>? _liveSummary;
  void observeServer(String value, {Map<String, dynamic>? summary}) {
    _liveSummary = summary;
    if (_observation != value) {
      _observation = value;
      if (cache.resources == null && !_libraryChanges.isClosed) {
        _libraryChanges.add(null);
      }
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  @override
  String get storageDescription => '资料保存在服务器';
  final _codec = WorkspaceInformationCodec();
  final _changes = StreamController<WorkspaceRecordRef?>.broadcast();
  @override
  Stream<WorkspaceRecordRef?> get changes => _changes.stream;
  int _mutationGeneration = 0, _refreshedMutation = 0;
  Future<void>? _mutationRefresh;
  Future<void> _refreshMutations() => _mutationRefresh ??= (() async {
    while (_refreshedMutation != _mutationGeneration) {
      final generation = _mutationGeneration;
      await cache.synchronize(requireFresh: true);
      _refreshedMutation = generation;
    }
  })().whenComplete(() => _mutationRefresh = null);
  void notifyConnectionChanged() {
    if (cache.resources != null) {
      _mutationGeneration++;
      unawaited(_refreshMutations().catchError((Object _) {}));
    } else if (!_libraryChanges.isClosed) {
      _libraryChanges.add(null);
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void>? _closeFuture;
  bool _passwordsDisposed = false;
  Future<void> dispose() =>
      _closeFuture ??= _dispose().catchError((Object e, StackTrace stack) {
        _closeFuture = null;
        Error.throwWithStackTrace(e, stack);
      });
  Future<void> _dispose() async {
    await onClosing?.call(this);
    if (runtime case final RemoteWorkspaceRuntime current) {
      await current.release();
    }
    if (!_passwordsDisposed) {
      _passwordsDisposed = true;
      proposalPasswords.dispose();
    }
    Object? firstError;
    StackTrace? firstStack;
    Future<void> close(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (e, stack) {
        firstError ??= e;
        firstStack ??= stack;
      }
    }

    // Each coordinator drains its own original operations. A cleanup failure
    // must not skip closing unrelated App handles or strand its HTTP client.
    // Private pending cleanup records remain available to their own recovery.
    await close(_fileActions.dispose);
    await close(backups.dispose);
    await close(settings.dispose);
    await close(hosts.dispose);
    await close(credentials.dispose);
    await close(files.dispose);
    cache.dispose();
    client.close();
    await close(_libraryChanges.close);
    await close(_changes.close);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }

  Future<T> _remote<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      throw switch (e.code) {
        'unauthorized' => const WorkspaceFailure(
          'unauthorized',
          '连接身份无效，请重新填写 Token。',
        ),
        'server_changed' => const WorkspaceFailure(
          'server_changed',
          '服务器已变化，请重新确认连接。',
        ),
        'version_conflict' ||
        'information_conflict' ||
        'operation_conflict' ||
        'template_changed' => const WorkspaceFailure(
          'conflict',
          '资料已变化，请重新读取后再修改。',
        ),
        'preview_expired' => const WorkspaceFailure(
          'preview_expired',
          '预览已关闭或服务已重开，请重新预览。',
        ),
        'preview_busy' => const WorkspaceFailure(
          'preview_busy',
          '待核对的模板预览过多，请先关闭已有预览。',
        ),
        'template_unavailable' => const WorkspaceFailure(
          'template_unavailable',
          '目标模板已停用或移除，请重新选择。',
        ),
        'conflict' || 'selection_expired' || 'validation' => WorkspaceFailure(
          e.code,
          e.code == 'selection_expired' ? '附件选择已失效，请重新选择。' : '资料或模板已变化，请重新核对。',
          fieldErrors: e.fieldErrors,
        ),
        'invalid_information' || 'invalid_request' => const WorkspaceFailure(
          'validation',
          '资料内容无效，请核对填写内容。',
        ),
        'not_found' => const WorkspaceFailure('not_found', '资料已不存在。'),
        _ => const WorkspaceFailure('unavailable', '无法连接服务器，请检查连接后重试。'),
      };
    }
  }

  Future<Map<String, dynamic>> _catalog() async {
    if (cache.resources == null) {
      return client.request('GET', '/v1/owner/catalog');
    }
    if (_mutationGeneration != _refreshedMutation) await _refreshMutations();
    return Map<String, dynamic>.from(cache.resources!['catalog'] as Map);
  }

  Map<String, String> _tagNames(Map<String, dynamic> catalog) => {
    for (final t in catalog['tags'] as List)
      t['id'] as String: t['name'] as String,
  };
  Future<List<WorkspaceRecordSummary>> _summaries() async {
    if (cache.resources != null) {
      return [
        for (final e in cache.resources!.entries)
          if (e.key.startsWith('record:'))
            workspaceDetailFromJson(e.value).record,
      ];
    }
    final data = await client.request('GET', '/v1/owner/summaries');
    final tags = _tagNames(await _catalog());
    return [
      for (final raw in data['items'] as List)
        _codec.summary(
          core.informationFromJson(raw as Map<String, dynamic>),
          tagNames: tags,
        ),
      for (final raw in data['credentials'] as List? ?? const [])
        recordSummaryFromJson(raw),
    ];
  }

  Future<core.InformationItem> _item(WorkspaceRecordRef ref) async {
    if (ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '此入口的联网接入尚未完成。');
    }
    return core.informationFromJson(
      await client.request(
        'GET',
        '/v1/owner/information/${Uri.encodeComponent(ref.id)}',
      ),
    );
  }

  @override
  Future<WorkspaceSummary> loadSummary() => _remote(() async {
    final summary =
        _liveSummary ??
        (await client.request('GET', '/v1/owner/updates'))['summary'] as Map;
    return WorkspaceSummary(
      records: summary['records'] as int,
      pending: summary['pending'] as int,
      proposals: summary['proposals'] as int,
    );
  });

  @override
  Future<WorkspaceCatalog> loadCatalog() => _remote(
    () async => workspaceCatalogFromJson((await _catalog())['workspace']),
  );

  @override
  Future<Map<String, Object?>> loadTemplate(String typeId) => _remote(() async {
    final data = await _catalog();
    final definition = (data['templates'] as List)
        .cast<Map<String, dynamic>>()
        .where((d) => d['id'] == typeId)
        .firstOrNull;
    if (definition == null) {
      throw const WorkspaceFailure('not_found', '模板不可用，请重新读取。');
    }
    return definition;
  });

  @override
  Future<WorkspaceAdoptionPreview> previewAdoption(
    WorkspaceAdoptionDraft draft,
  ) => _remote(
    () async => adoptionPreviewFromJson(
      await client.request(
        'POST',
        '/v1/owner/adoption/previews',
        adoptionDraftToJson(draft),
      ),
    ),
  );
  @override
  Future<void> releaseAdoption(String planId) => _remote(() async {
    await client.request(
      'DELETE',
      '/v1/owner/adoption/previews/${Uri.encodeComponent(planId)}',
    );
  });
  @override
  Future<WorkspaceRecordReceipt> applyAdoption(
    String operationId,
    String planId,
  ) => _remote(() async {
    WorkspaceRecordReceipt receipt;
    try {
      receipt = adoptionReceiptFromJson(
        await client.request('POST', '/v1/owner/adoption/changes', {
          'wireVersion': 1,
          'operationId': operationId,
          'planId': planId,
        }),
      );
    } on RemoteFailure catch (e) {
      if (const {
        'unauthorized',
        'invalid_request',
        'validation',
        'conflict',
        'version_conflict',
        'information_conflict',
        'operation_conflict',
        'preview_expired',
        'template_changed',
        'template_unavailable',
      }.contains(e.code)) {
        rethrow;
      }
      throw const WorkspaceFailure('unknown_outcome', '模板切换结果暂时无法确认，请核对原操作。');
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '模板切换结果暂时无法确认，请核对原操作。');
    }
    notifyConnectionChanged();
    return receipt;
  });

  @override
  Future<WorkspaceDetail> readDetail(
    WorkspaceRecordRef ref,
  ) => _remote(() async {
    if (cache.resources != null) {
      if (_mutationGeneration != _refreshedMutation) await _refreshMutations();
      final value = cache.resources!['record:${ref.kind.name}:${ref.id}'];
      if (value == null) throw const WorkspaceFailure('not_found', '资料已不存在。');
      return workspaceDetailFromJson(value);
    }
    if (ref.kind == WorkspaceRecordKind.credential) {
      return credentialWorkspaceDetail(await credentials.read(ref));
    }
    final detail = _codec.decode(
      await _item(ref),
      tagNames: _tagNames(await _catalog()),
    );
    final state = workspacePluginTemplateState(
      (await plugins.load()).packages,
      detail.record.type.id,
      detail.definition['packageId'] as String?,
    );
    return WorkspaceDetail(
      record: detail.record,
      version: detail.version,
      templateState: detail.templateState == WorkspaceTemplateState.available
          ? state
          : detail.templateState,
      definition: detail.definition,
      values: detail.values,
      relations: detail.relations,
      incomingRelations: detail.incomingRelations,
      fieldIds: detail.fieldIds,
      fieldOverrides: detail.fieldOverrides,
      retainedFields: detail.retainedFields,
      retainedRelations: detail.retainedRelations,
    );
  });

  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) => _remote(() async {
    final wanted = refs.toSet();
    return (await _summaries()).where((r) => wanted.contains(r.ref)).toList();
  });

  @override
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) => _remote(() async {
    final catalog = await _catalog();
    final parents = {
      for (final d in catalog['directories'] as List)
        d['id'] as String: d['parentId'] as String?,
    };
    bool inDirectory(String? id) {
      if (query.directoryId == null || query.directoryId == 'all') return true;
      if (query.directoryId == 'unfiled') return id == null;
      final seen = <String>{};
      while (id != null && seen.add(id)) {
        if (id == query.directoryId) return true;
        id = parents[id];
      }
      return false;
    }

    final words = query.keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    final items = (await _summaries())
        .where(
          (r) =>
              inDirectory(r.directoryId) &&
              (query.typeId == null ||
                  workspaceTypeMatches(r.type.id, query.typeId!)) &&
              (query.tagId == null || r.tags.any((t) => t.id == query.tagId)) &&
              words.every(
                ('${r.name} ${r.description} ${r.type.name} ${r.tags.map((t) => t.name).join(' ')}')
                    .toLowerCase()
                    .contains,
              ),
        )
        .toList();
    sortWorkspaceSummaries(
      items,
      query.sort,
      manualRecords: (catalog['recordOrder'] as List)
          .map(recordRefFromJson)
          .toList(),
      manualDirectories: [
        for (final d in libraryDirectoryTree(
          workspaceCatalogFromJson(catalog['workspace']),
        ))
          d.id,
        null,
      ],
    );
    final groups = <String, List<WorkspaceRecordSummary>>{};
    for (final item in items) {
      final group = switch (query.grouping) {
        WorkspaceGrouping.none => '',
        WorkspaceGrouping.type => item.type.id,
        WorkspaceGrouping.directory => item.directoryId ?? 'unfiled',
      };
      groups.putIfAbsent(group, () => []).add(item);
    }
    items
      ..clear()
      ..addAll(groups.values.expand((items) => items));
    if (query.limit < 1 || query.limit > 500 || query.offset < 0) {
      throw const WorkspaceFailure('invalid_query', '无效的分页范围。');
    }
    final offset = query.offset >= items.length
        ? (items.isEmpty ? 0 : (items.length - 1) ~/ query.limit * query.limit)
        : query.offset;
    final selection = items.any((r) => r.ref == keepSelection)
        ? keepSelection
        : items.skip(offset).firstOrNull?.ref;
    return WorkspaceResults(
      items: items.skip(offset).take(query.limit),
      total: items.length,
      groupCounts: {for (final e in groups.entries) e.key: e.value.length},
      offset: offset,
      selection: selection,
      selectionIndex: selection == null
          ? null
          : items.indexWhere((r) => r.ref == selection),
    );
  });

  Future<WorkspaceSaveResult> _save(
    String id,
    core.InformationDraftInput? input, {
    Future<core.InformationRecordReceipt> Function()? write,
  }) async {
    late core.InformationRecordReceipt receipt;
    try {
      receipt = await (write?.call() ?? client.save(id, input!));
    } on RemoteFailure catch (e) {
      if (const {
        'unauthorized',
        'server_changed',
        'invalid_information',
        'invalid_request',
        'version_conflict',
        'information_conflict',
        'operation_conflict',
        'conflict',
        'selection_expired',
        'validation',
      }.contains(e.code)) {
        rethrow;
      }
      throw const WorkspaceFailure(
        'unknown_outcome',
        '保存结果尚未确认，请先核对原操作，不要重新添加。',
      );
    }
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      receipt.itemId,
    );
    if (cache.resources != null) await cache.synchronize(requireFresh: true);
    if (!_changes.isClosed) _changes.add(ref);
    try {
      final detail = await readDetail(ref);
      if (detail.version != receipt.version) {
        throw const WorkspaceFailure('unknown_outcome', '资料已再次变化，请核对本次操作结果。');
      }
      return WorkspaceSaved(detail);
    } on Object {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '保存已提交，但暂时无法读取结果，请核对原操作。',
      );
    }
  }

  @override
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft) =>
      _remote(() async {
        if (draft.fileSelections.isEmpty && draft.legacyTemplateId == null) {
          final definition = await loadTemplate(draft.typeId);
          if (draft.expectedTemplateVersion != definition['templateVersion'] ||
              draft.expectedTemplateDigest != definition['packageDigest']) {
            throw const WorkspaceFailure('conflict', '模板已变化，请重新打开表单。');
          }
          return _save(draft.operationId, _codec.create(draft, definition));
        }
        return _save(
          draft.operationId,
          null,
          write: () async {
            final receipt = core.InformationRecordReceipt.fromJson(
              await client.request(
                'POST',
                '/v1/owner/files/forms',
                workspaceCreateToJson(draft),
              ),
            );
            if (receipt.command?.digest != _codec.createCommand(draft).digest ||
                receipt.baseVersion != null) {
              throw const FormatException('Mismatched form receipt');
            }
            files.committed(draft.fileSelections.values);
            return receipt;
          },
        );
      });
  @override
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) => _remote(
    () async => _save(
      edit.operationId,
      _codec.edit(edit, await _item(edit.record.ref)),
    ),
  );

  @override
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(
    String operationId,
  ) => _remote(() async {
    final r = await client.receipt(operationId);
    final lifecycle = await _history.receipt(operationId);
    if (r != null && lifecycle != null) {
      throw const WorkspaceFailure('unknown_outcome', '原操作编号对应多种结果，无法确认。');
    }
    if (lifecycle != null) {
      await _refreshResolvedRecord(lifecycle.result.ref);
      return lifecycle;
    }
    if (r == null) return null;
    final command = r.command;
    if (command == null) {
      throw const WorkspaceFailure('unknown_outcome', '此旧操作缺少原表单标识，请核对操作结果。');
    }
    final ref = WorkspaceRecordRef(WorkspaceRecordKind.information, r.itemId);
    await _refreshResolvedRecord(ref);
    return WorkspaceOperationReceipt(
      operationId: r.operationId,
      intent: WorkspaceOperationIntent(
        kind: command.adoptionPlanId != null
            ? WorkspaceOperationKind.adoptTemplate
            : r.baseVersion == null
            ? WorkspaceOperationKind.create
            : WorkspaceOperationKind.edit,
        ref: r.baseVersion == null ? null : ref,
        typeId: command.typeId,
        expectedVersion: r.baseVersion,
        planId: command.adoptionPlanId,
        legacyTemplateId: command.legacyTemplateId,
        legacyTemplateVersion: command.legacyTemplateVersion,
      ),
      result: WorkspaceRecordReceipt(ref: ref, version: r.version),
    );
  });

  Future<void> _refreshResolvedRecord(WorkspaceRecordRef ref) async {
    // Resolved file/save receipts must publish their updated projection
    // before the caller closes the editor or reads the new file.
    // This also covers records moved out of their previous directory.
    // Failure remains an unknown outcome; this never submits another write.
    if (cache.resources != null) await cache.synchronize(requireFresh: true);
    if (!_changes.isClosed) _changes.add(ref);
  }
}
