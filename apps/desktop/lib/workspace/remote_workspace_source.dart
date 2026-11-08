import 'dart:async';
import 'package:info_core/info_core.dart' as core;
import 'package:info_remote/owner_client.dart';
import 'workspace_source.dart';
import 'workspace_information_codec.dart';
import 'workspace_order.dart';
import 'unavailable_workspace_sources.dart';

/// Live projections through the existing UI seam; no local library or body
/// cache. Shared codecs preserve the exact ordinary owner display/edit rules.
class RemoteWorkspaceSource extends UnavailableWorkspaceSource
    implements WorkspaceStorageLocation {
  RemoteWorkspaceSource(this.client);
  final OwnerClient client;
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
  Future<WorkspaceCatalog> loadCatalog() => _remote(() async {
    final data = await _catalog();
    final records = await _summaries();
    final definitions = (data['templates'] as List).cast<Map>();
    return WorkspaceCatalog(
      version: data['version'] as int,
      directories: [
        for (final d in data['directories'] as List)
          WorkspaceDirectory(
            d['id'] as String,
            d['name'] as String,
            parentId: d['parentId'] as String?,
          ),
      ],
      tags: [
        for (final t in data['tags'] as List)
          WorkspaceTag(t['id'] as String, t['name'] as String),
      ],
      types: [
        for (final d in definitions)
          WorkspaceType(
            d['id'] as String,
            d['name'] as String,
            d['icon'] as String? ?? 'file',
          ),
      ],
      creatableTypes: [
        for (final d in definitions)
          if (!const {'file', 'resume', 'credential'}.contains(d['id']))
            WorkspaceType(
              d['id'] as String,
              d['name'] as String,
              d['icon'] as String? ?? 'file',
            ),
      ],
      directoryCounts: {
        for (final d in data['directories'] as List)
          d['id'] as String: records
              .where((r) => r.directoryId == d['id'])
              .length,
      },
      tagCounts: {
        for (final t in data['tags'] as List)
          t['id'] as String: records
              .where((r) => r.tags.any((tag) => tag.id == t['id']))
              .length,
      },
    );
  });

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
    () async =>
        _codec.decode(await _item(ref), tagNames: _tagNames(await _catalog())),
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
    sortWorkspaceSummaries(items, query.sort);
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
    core.InformationDraftInput input,
  ) async {
    late core.InformationRecordReceipt receipt;
    try {
      receipt = await client.save(id, input);
    } on RemoteFailure catch (e) {
      if (const {
        'unauthorized',
        'server_changed',
        'invalid_information',
        'invalid_request',
        'version_conflict',
        'information_conflict',
        'operation_conflict',
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
        if (draft.fileSelections.isNotEmpty || draft.legacyTemplateId != null) {
          throw const WorkspaceFailure('unsupported', '此录入方式的联网接入尚未完成。');
        }
        final definition = await loadTemplate(draft.typeId);
        if (draft.expectedTemplateVersion != definition['templateVersion'] ||
            draft.expectedTemplateDigest != definition['packageDigest']) {
          throw const WorkspaceFailure('conflict', '模板已变化，请重新打开表单。');
        }
        return _save(draft.operationId, _codec.create(draft, definition));
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
