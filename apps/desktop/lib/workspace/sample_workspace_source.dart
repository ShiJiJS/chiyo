import 'dart:async';
import 'dart:convert';
import 'sample_workspace_fixture.dart';
import 'workspace_source.dart';

enum SampleWorkspaceScenario { ready, empty, waiting, failure }

/// The isolated composition root creates this provider. All values are the
/// approved prototype's fictional data; no production adapter imports it.
class SampleWorkspaceSource implements WorkspaceSource {
  SampleWorkspaceScenario _scenario = SampleWorkspaceScenario.ready;
  final _waiting = <Completer<void>>[];
  final _changes = StreamController<WorkspaceRecordRef?>.broadcast();
  @override
  Stream<WorkspaceRecordRef?> get changes => _changes.stream;
  Future<void>? _loading;
  late WorkspaceCatalog _catalog;
  final _initial = <WorkspaceRecordRef, WorkspaceDetail>{};
  final _records = <WorkspaceRecordRef, WorkspaceDetail>{};
  final _operations =
      <String, ({String fingerprint, WorkspaceSaveResult result})>{};
  WorkspaceFailure? nextSaveFailure;
  int _epoch = 0, _clock = 0;
  bool _disposed = false;
  static const initial = WorkspaceSummary(
    records: 31,
    pending: 5,
    proposals: 2,
  );
  SampleWorkspaceScenario get scenario => _scenario;

  void setScenario(SampleWorkspaceScenario value) {
    _epoch++;
    for (final request in _waiting) {
      request.completeError(const WorkspaceFailure('cancelled', '已切换预览状态。'));
    }
    _waiting.clear();
    _scenario = value;
  }

  Future<void> _ensureData() => _loading ??= () async {
    final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
    final rows = (data['records'] as List).cast<Map<String, dynamic>>();
    final tagNames = <String>{
      for (final row in rows) ...List<String>.from(row['tags'] ?? []),
    };
    final tags = {
      for (final (index, name) in tagNames.indexed)
        name: WorkspaceTag('tag-$index', name),
    };
    final types = <String, WorkspaceType>{};
    WorkspaceType type(Map<String, dynamic> row) {
      final id =
          row['templateId'] as String? ??
          (row['kind'] == 'resume' ? 'file' : row['kind'] as String);
      return types.putIfAbsent(id, () {
        final definition = row['definition'] as Map<String, dynamic>?;
        const names = {
          'server': '服务器信息',
          'service': '应用与服务',
          'profile': '个人档案',
          'document': '文档',
          'file': '文件',
          'credential': '凭据',
          'generic': '通用资料',
        };
        const icons = {
          'server': 'server',
          'service': 'layers',
          'profile': 'user',
          'document': 'book',
          'file': 'file',
          'credential': 'key',
        };
        return WorkspaceType(
          id,
          definition?['name'] as String? ?? names[id] ?? '通用资料',
          definition?['icon'] as String? ?? icons[id] ?? 'file',
        );
      });
    }

    final refs = {
      for (final row in rows)
        row['id'] as String: WorkspaceRecordRef(
          row['kind'] == 'credential'
              ? WorkspaceRecordKind.credential
              : WorkspaceRecordKind.information,
          row['id'] as String,
        ),
    };
    for (final row in rows) {
      final ref = refs[row['id']]!;
      final rawDirectory = row['directory'] as String?;
      final record = WorkspaceRecordSummary(
        ref: ref,
        name: row['name'] as String,
        description: row['summary'] as String? ?? '',
        type: type(row),
        updatedAt: DateTime.parse('${row['updatedAt']}T00:00:00Z'),
        directoryId: rawDirectory == 'unfiled' ? null : rawDirectory,
        tags: [for (final name in row['tags'] as List? ?? []) tags[name]!],
      );
      final relations = row['relations'] as Map<String, dynamic>? ?? {};
      _initial[ref] = WorkspaceDetail(
        record: record,
        version: 1,
        definition: Map<String, Object?>.from(row['definition'] as Map? ?? {}),
        // A credential's actual content is deliberately not a generic detail.
        values: ref.kind == WorkspaceRecordKind.credential
            ? {}
            : Map<String, Object?>.from(row['values'] as Map? ?? {}),
        relations: {
          for (final entry in relations.entries)
            entry.key: [
              for (final id in entry.value as List)
                if (refs[id] != null) refs[id]!,
            ],
        },
      );
    }
    _records.addAll(_initial);
    _catalog = WorkspaceCatalog(
      directories: [
        for (final row in data['directories'] as List)
          WorkspaceDirectory(
            row['id'] as String,
            row['name'] as String,
            parentId: row['parent'] as String?,
          ),
      ],
      tags: tags.values,
      types: types.values,
    );
  }();

  Future<void> _readable() async {
    final epoch = _epoch;
    if (_disposed) throw const WorkspaceFailure('cancelled', '预览已关闭。');
    if (_scenario == SampleWorkspaceScenario.waiting) {
      final request = Completer<void>();
      _waiting.add(request);
      await request.future;
    }
    if (_scenario == SampleWorkspaceScenario.failure) {
      throw const WorkspaceFailure('sample_unavailable', '暂时无法读取资料，请重试。');
    }
    await _ensureData();
    if (_disposed || epoch != _epoch) {
      throw const WorkspaceFailure('cancelled', '已切换预览状态。');
    }
  }

  @override
  Future<WorkspaceSummary> loadSummary() async {
    await _readable();
    return _scenario == SampleWorkspaceScenario.empty
        ? const WorkspaceSummary.empty()
        : WorkspaceSummary(
            records: _records.length,
            pending: initial.pending,
            proposals: initial.proposals,
          );
  }

  @override
  Future<WorkspaceCatalog> loadCatalog() async {
    await _readable();
    return _catalog;
  }

  bool _inDirectory(String? id, String? ancestor) {
    if (ancestor == null || ancestor == 'all') return true;
    if (ancestor == 'unfiled') return id == null;
    final visited = <String>{};
    while (id != null && visited.add(id)) {
      if (id == ancestor) return true;
      final matches = _catalog.directories.where((d) => d.id == id);
      id = matches.isEmpty ? null : matches.first.parentId;
    }
    return false;
  }

  @override
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) async {
    await _readable();
    if (query.offset < 0 || query.limit < 1 || query.limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的分页范围。');
    }
    final terms = query.keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty);
    final items = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : _records.values.map((d) => d.record).where((r) {
            final metadata =
                '${r.name} ${r.description} ${r.type.name} ${r.tags.map((t) => t.name).join(' ')}'
                    .toLowerCase();
            return _inDirectory(r.directoryId, query.directoryId) &&
                (query.typeId == null || r.type.id == query.typeId) &&
                (query.tagId == null ||
                    r.tags.any((t) => t.id == query.tagId)) &&
                terms.every(metadata.contains);
          }).toList();
    String group(WorkspaceRecordSummary record) => switch (query.grouping) {
      WorkspaceGrouping.none => '',
      WorkspaceGrouping.type => record.type.id,
      WorkspaceGrouping.directory => record.directoryId ?? 'unfiled',
    };
    items.sort((a, b) {
      final grouped = group(a).compareTo(group(b));
      if (grouped != 0) return grouped;
      final sorted = query.sort == WorkspaceSort.name
          ? a.name.compareTo(b.name)
          : b.updatedAt.compareTo(a.updatedAt);
      return sorted != 0 ? sorted : a.ref.key.compareTo(b.ref.key);
    });
    final counts = <String, int>{};
    for (final r in items) {
      counts.update(group(r), (count) => count + 1, ifAbsent: () => 1);
    }
    final selection = items.any((r) => r.ref == keepSelection)
        ? keepSelection
        : (items.isEmpty ? null : items.skip(query.offset).firstOrNull?.ref);
    return WorkspaceResults(
      items: items.skip(query.offset).take(query.limit),
      total: items.length,
      offset: query.offset,
      selection: selection,
      groupCounts: counts,
    );
  }

  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async {
    await _readable();
    final detail = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[ref];
    if (detail == null) {
      throw const WorkspaceFailure('not_found', '资料已不存在，请返回列表。');
    }
    return detail;
  }

  @override
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) async {
    try {
      await _readable();
    } on WorkspaceFailure catch (failure) {
      return WorkspaceRejected(failure);
    }
    final fingerprint = jsonEncode({
      'target': edit.record.ref.key,
      'version': edit.expectedVersion,
      'name': edit.record.name,
      'description': edit.record.description,
      'type': edit.record.type.id,
      'directory': edit.record.directoryId,
      'tags': edit.record.tags.map((t) => t.id).toList(),
      'values': edit.values,
    });
    final previous = _operations[edit.operationId];
    if (previous != null) {
      return previous.fingerprint == fingerprint
          ? previous.result
          : const WorkspaceRejected(
              WorkspaceFailure('operation_conflict', '同一次保存不能用于不同内容。'),
            );
    }
    WorkspaceSaveResult result;
    final current = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[edit.record.ref];
    final fields = <String, String>{};
    if (edit.record.name.trim().isEmpty || edit.record.name.length > 160) {
      fields['name'] = '请输入1–160字的名称。';
    }
    if (edit.record.description.length > 2000) {
      fields['description'] = '说明不能超过2000字。';
    }
    final values = {...?current?.values, ...edit.values};
    for (final field in current?.definition['fields'] as List? ?? []) {
      if (field['required'] == true &&
          (values[field['key']]?.toString().trim() ?? '').isEmpty) {
        fields[field['key'] as String] = '请填写${field['label']}。';
      }
    }
    if (edit.operationId.trim().isEmpty || current == null) {
      result = const WorkspaceRejected(
        WorkspaceFailure('not_found', '保存目标或操作身份无效。'),
      );
    } else if (nextSaveFailure != null) {
      result = WorkspaceRejected(nextSaveFailure!);
      nextSaveFailure = null;
    } else if (current.version != edit.expectedVersion) {
      result = const WorkspaceRejected(
        WorkspaceFailure('conflict', '资料已更新，请重新读取并核对修改。'),
      );
    } else if (fields.isNotEmpty) {
      result = WorkspaceRejected(
        WorkspaceFailure('validation', '请检查标记的字段。', fieldErrors: fields),
      );
    } else if (edit.record.type.id != current.record.type.id ||
        (edit.record.directoryId != null &&
            !_catalog.directories.any(
              (d) => d.id == edit.record.directoryId && d.id != 'all',
            )) ||
        edit.record.tags.any(
          (t) => !_catalog.tags.any((known) => known.id == t.id),
        )) {
      result = const WorkspaceRejected(
        WorkspaceFailure('validation', '类型、目录或标签引用已失效。'),
      );
    } else if (edit.record.ref.kind == WorkspaceRecordKind.credential &&
        edit.values.isNotEmpty) {
      result = const WorkspaceRejected(
        WorkspaceFailure('unsupported', '凭据正文不通过普通资料接口读写。'),
      );
    } else {
      final detail = WorkspaceDetail(
        record: edit.record.copyWith(
          name: edit.record.name.trim(),
          updatedAt: DateTime.utc(
            2026,
            10,
            26,
          ).add(Duration(microseconds: _clock++)),
        ),
        version: current.version + 1,
        definition: current.definition,
        values: values,
        relations: current.relations,
      );
      _records[edit.record.ref] = detail;
      _changes.add(edit.record.ref);
      result = WorkspaceSaved(detail);
    }
    _operations[edit.operationId] = (fingerprint: fingerprint, result: result);
    return result;
  }

  void reset() {
    setScenario(SampleWorkspaceScenario.ready);
    _records
      ..clear()
      ..addAll(_initial);
    _operations.clear();
    nextSaveFailure = null;
    _clock = 0;
    if (!_disposed) _changes.add(null);
  }

  void dispose() {
    _disposed = true;
    setScenario(SampleWorkspaceScenario.ready);
    unawaited(_changes.close());
  }
}
