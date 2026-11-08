import 'dart:async';
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
import '../information_files.dart';

/// Live projections through the existing UI seam; no local library or body
/// cache. Shared codecs preserve the exact ordinary owner display/edit rules.
class RemoteWorkspaceSource extends UnavailableWorkspaceSource
    implements
        WorkspaceStorageLocation,
        WorkspaceLibraryMove,
        WorkspaceFileSelectionReleaser {
  RemoteWorkspaceSource(this.client, {InformationFilePicker? filePicker})
    : _observation = client.initialWorkspaceObservation {
    files = RemoteWorkspaceFiles(
      client,
      changed: notifyConnectionChanged,
      picker: filePicker ?? const NativeInformationFilePicker(),
    );
  }
  final OwnerClient client;
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
  ) => files.receipt(operationId);
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
    changed: notifyConnectionChanged,
  );
  @override
  late final WorkspaceApprovalSource approvals = RemoteWorkspaceApprovals(
    client,
    onChanged: notifyConnectionChanged,
  );
  String? _observation;
  void observeServer(String value) {
    if (_observation != value) {
      _observation = value;
      notifyConnectionChanged();
    }
  }

  @override
  String get storageDescription => '资料保存在服务器';
  final _codec = WorkspaceInformationCodec();
  final _changes = StreamController<WorkspaceRecordRef?>.broadcast();
  @override
  Stream<WorkspaceRecordRef?> get changes => _changes.stream;
  void notifyConnectionChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await files.dispose();
    client.close();
    await _changes.close();
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
        'version_conflict' || 'information_conflict' || 'operation_conflict' =>
          const WorkspaceFailure('conflict', '资料已变化，请重新读取后再修改。'),
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

  Future<Map<String, dynamic>> _catalog() =>
      client.request('GET', '/v1/owner/catalog');
  Map<String, String> _tagNames(Map<String, dynamic> catalog) => {
    for (final t in catalog['tags'] as List)
      t['id'] as String: t['name'] as String,
  };
  Future<List<WorkspaceRecordSummary>> _summaries() async {
    final data = await client.request('GET', '/v1/owner/summaries');
    final tags = _tagNames(await _catalog());
    return [
      for (final raw in data['items'] as List)
        _codec.summary(
          core.informationFromJson(raw as Map<String, dynamic>),
          tagNames: tags,
        ),
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
    final summary = (await _catalog())['summary'] as Map;
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
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) => _remote(
    () async {
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
    },
  );

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
    if (r == null) return null;
    final command = r.command;
    if (command == null) {
      throw const WorkspaceFailure('unknown_outcome', '此旧操作缺少原表单标识，请核对操作结果。');
    }
    final ref = WorkspaceRecordRef(WorkspaceRecordKind.information, r.itemId);
    return WorkspaceOperationReceipt(
      operationId: r.operationId,
      intent: WorkspaceOperationIntent(
        kind: r.baseVersion == null
            ? WorkspaceOperationKind.create
            : WorkspaceOperationKind.edit,
        ref: r.baseVersion == null ? null : ref,
        typeId: command.typeId,
        expectedVersion: r.baseVersion,
      ),
      result: WorkspaceRecordReceipt(ref: ref, version: r.version),
    );
  });
}
