import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'sample_workspace_fixture.dart';
import 'workspace_source.dart';

part 'sample_workspace_history.dart';

enum SampleWorkspaceScenario { ready, empty, waiting, failure }

/// The isolated composition root creates this provider. All values are the
/// approved prototype's fictional data; no production adapter imports it.
class SampleWorkspaceSource implements WorkspaceSource {
  SampleWorkspaceSource({
    String fixtureJson = sampleWorkspaceJson,
    DateTime Function()? now,
  }) : _fixtureJson = fixtureJson,
       _now = now ?? (() => DateTime.utc(2026, 10, 26));
  final DateTime Function() _now;
  final _revisions = <WorkspaceRecordRef, List<WorkspaceArchive>>{};
  final _recycled =
      <String, ({WorkspaceRecycleEntry entry, WorkspaceArchive archive})>{};
  final _recordOperations =
      <String, ({String fingerprint, WorkspaceRecordReceipt receipt})>{};
  final _versions = <WorkspaceRecordRef, int>{};
  int _nextRecycle = 0;
  String _fingerprint(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  final String _fixtureJson;
  static const _genericDefinition = <String, Object?>{
    'name': '通用资料',
    'fields': [
      {'key': 'body', 'label': '内容', 'type': 'multiline'},
    ],
    'relations': [
      {'key': 'related', 'label': '相关资料', 'targetTemplates': <String>[]},
    ],
    'sections': [
      {'kind': 'text', 'title': '内容', 'key': 'body'},
      {'kind': 'relations', 'title': '相关资料', 'key': 'related'},
    ],
  };

  Map<String, Object?> _genericDefinitionFor(Map values) => {
    ..._genericDefinition,
    'fields': [
      if (!values.containsKey('body') || values['body'] is String)
        ..._genericDefinition['fields'] as List,
      for (final key in values.keys)
        if (key != 'body' && values[key] is String)
          {'key': key, 'label': key, 'type': 'multiline'},
    ],
    'sections': [
      {'kind': 'text', 'title': '内容', 'key': 'body'},
      for (final key in values.keys)
        if (key != 'body') {'kind': 'text', 'title': key, 'key': key},
      {'kind': 'relations', 'title': '相关资料', 'key': 'related'},
    ],
  };
  SampleWorkspaceScenario _scenario = SampleWorkspaceScenario.ready;
  final _waiting = <Completer<void>>[];
  final _changes = StreamController<WorkspaceRecordRef?>.broadcast();
  @override
  Stream<WorkspaceRecordRef?> get changes => _changes.stream;
  Future<void>? _loading;
  late WorkspaceCatalog _catalog;
  WorkspaceCatalog? _initialCatalog;
  int _catalogVersion = 1, _nextDirectory = 0;
  final _directoryOperations =
      <String, ({String fingerprint, WorkspaceDirectory? directory})>{};
  final _initial = <WorkspaceRecordRef, WorkspaceDetail>{};
  final _records = <WorkspaceRecordRef, WorkspaceDetail>{};
  final _operations =
      <String, ({String fingerprint, WorkspaceSaveResult result})>{};
  WorkspaceFailure? nextSaveFailure;
  int _epoch = 0, _clock = 0, _nextRecord = 0;
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
    final data = jsonDecode(_fixtureJson) as Map<String, dynamic>;
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
          (row['kind'] == 'resume'
              ? 'file'
              : row['kind'] == 'note'
              ? 'generic'
              : row['kind'] as String);
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
        definition: Map<String, Object?>.from(
          row['definition'] as Map? ??
              (record.type.id == 'generic'
                  ? _genericDefinitionFor(row['values'] as Map? ?? {})
                  : {}),
        ),
        // A credential's actual content is deliberately not a generic detail.
        values: ref.kind == WorkspaceRecordKind.credential
            ? {}
            : Map<String, Object?>.from(row['values'] as Map? ?? {}),
        relations: {
          for (final entry in relations.entries)
            entry.key: [
              for (final id in entry.value as List)
                refs[id] ??
                    WorkspaceRecordRef(
                      WorkspaceRecordKind.information,
                      id as String,
                    ),
            ],
        },
      );
    }
    _records.addAll(_initial);
    for (final detail in _initial.values) {
      _versions[detail.record.ref] = detail.version;
    }
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
    _initialCatalog = _catalog;
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
    _expireHistory();
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
    final records = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : _records.values.map((d) => d.record);
    return WorkspaceCatalog(
      version: _catalogVersion,
      recycledCount: _scenario == SampleWorkspaceScenario.empty
          ? 0
          : _recycled.length,
      directories: _catalog.directories,
      tags: _catalog.tags,
      types: _catalog.types,
      directoryCounts: {
        for (final directory in _catalog.directories)
          directory.id: records
              .where((r) => _inDirectory(r.directoryId, directory.id))
              .length,
      },
      tagCounts: {
        for (final tag in _catalog.tags)
          tag.id: records
              .where((r) => r.tags.any((t) => t.id == tag.id))
              .length,
      },
    );
  }

  @override
  Future<WorkspaceDirectory?> changeDirectory(
    WorkspaceDirectoryChange change,
  ) async {
    await _readable();
    final fingerprint = _fingerprint({
      'action': change.action.name,
      'version': change.expectedVersion,
      'target': change.directoryId,
      'name': change.name,
      'parent': change.parentId,
    });
    final previous = _directoryOperations[change.operationId];
    if (previous != null) {
      if (previous.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同目录内容。');
      }
      return previous.directory;
    }
    if (change.operationId.trim().isEmpty) {
      throw const WorkspaceFailure('validation', '目录操作身份不能为空。');
    }
    if (change.expectedVersion != _catalogVersion) {
      throw const WorkspaceFailure('conflict', '目录已变化，请重新读取后核对。');
    }
    final current = _catalog.directories
        .where((d) => d.id == change.directoryId)
        .firstOrNull;
    final creating = change.action == WorkspaceDirectoryAction.create;
    if ((!creating &&
            (current == null || ['all', 'unfiled'].contains(current.id))) ||
        (creating && change.directoryId != null)) {
      throw const WorkspaceFailure('not_found', '目录已不存在或不能修改。');
    }
    WorkspaceDirectory? result;
    if (change.action == WorkspaceDirectoryAction.delete) {
      if (_catalog.directories.any((d) => d.parentId == current!.id) ||
          (_scenario != SampleWorkspaceScenario.empty &&
              _records.values.any(
                (d) => d.record.directoryId == current!.id,
              ))) {
        throw const WorkspaceFailure(
          'directory_not_empty',
          '目录包含资料、凭据或子目录，请先移出后再删除。',
        );
      }
    } else {
      final name = change.name.trim();
      final errors = <String, String>{};
      if (name.isEmpty ||
          change.name.length > 200 ||
          name.contains('/') ||
          name.contains(r'\')) {
        errors['name'] = '请输入1–200字的目录名，不包含斜线。';
      }
      final visited = <String>{if (!creating) current!.id};
      var parent = change.parentId;
      while (parent != null) {
        final found = _catalog.directories
            .where((d) => d.id == parent && !['all', 'unfiled'].contains(d.id))
            .firstOrNull;
        if (found == null || !visited.add(parent)) {
          errors['parent'] = '请选择现存目录，不能移入自身或子目录。';
          break;
        }
        parent = found.parentId;
      }
      if (_catalog.directories.any(
        (d) =>
            d.id != current?.id &&
            d.parentId == change.parentId &&
            d.name.toLowerCase() == name.toLowerCase(),
      )) {
        errors['name'] = '此位置已有同名目录。';
      }
      if (errors.isNotEmpty) {
        throw WorkspaceFailure(
          'validation',
          '请检查标记的目录内容。',
          fieldErrors: errors,
        );
      }
      result = WorkspaceDirectory(
        creating ? 'preview-directory-${++_nextDirectory}' : current!.id,
        name,
        parentId: change.parentId,
      );
    }
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
    final directories = [..._catalog.directories];
    if (current != null) {
      final index = directories.indexWhere((d) => d.id == current.id);
      if (result == null) {
        directories.removeAt(index);
      } else {
        directories[index] = result;
      }
    } else if (result != null) {
      directories.add(result);
    }
    _catalog = WorkspaceCatalog(
      directories: directories,
      tags: _catalog.tags,
      types: _catalog.types,
    );
    _catalogVersion++;
    if (_scenario == SampleWorkspaceScenario.empty) {
      _records.clear();
      _scenario = SampleWorkspaceScenario.ready;
    }
    _directoryOperations[change.operationId] = (
      fingerprint: fingerprint,
      directory: result,
    );
    _changes.add(null);
    return result;
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
  Future<Map<String, Object?>> loadTemplate(String typeId) async {
    await _readable();
    if (typeId == 'generic') return _genericDefinition;
    final template = _initial.values
        .where((d) => d.record.type.id == typeId)
        .firstOrNull;
    if (template == null ||
        template.record.ref.kind == WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('not_found', '资料模板不可用。');
    }
    return template.definition;
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
    final items = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : _records.values.map((d) => d.record).where((r) {
            return _inDirectory(r.directoryId, query.directoryId) &&
                (query.typeId == null || r.type.id == query.typeId) &&
                (query.tagId == null ||
                    r.tags.any((t) => t.id == query.tagId)) &&
                _matchesKeyword(r, query.keyword);
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
    final offset = _pageOffset(query.offset, query.limit, items.length);
    final selection = items.any((r) => r.ref == keepSelection)
        ? keepSelection
        : (items.isEmpty ? null : items.skip(offset).firstOrNull?.ref);
    return WorkspaceResults(
      items: items.skip(offset).take(query.limit),
      total: items.length,
      offset: offset,
      selection: selection,
      selectionIndex: selection == null
          ? null
          : items.indexWhere((r) => r.ref == selection),
      groupCounts: counts,
    );
  }

  bool _matchesKeyword(WorkspaceRecordSummary record, String keyword) {
    final metadata =
        '${record.name} ${record.description} ${record.type.name} ${record.tags.map((t) => t.name).join(' ')}'
            .toLowerCase();
    return keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .every(metadata.contains);
  }

  Map<String, Object?>? _relationRule(
    Map<String, Object?> definition,
    String key,
  ) {
    for (final rule in definition['relations'] as List? ?? []) {
      if (rule['key'] == key) return Map<String, Object?>.from(rule as Map);
    }
    return null;
  }

  bool _acceptsRelation(
    Map<String, Object?> rule,
    WorkspaceRecordSummary target,
  ) {
    final types = rule['targetTemplates'] as List? ?? [];
    return types.isEmpty || types.contains(target.type.id);
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async {
    await _readable();
    if (query.offset < 0 || query.limit < 1 || query.limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的关联分页范围。');
    }
    final source = query.source == null
        ? _initial.values
              .where((d) => d.record.type.id == query.typeId)
              .firstOrNull
        : _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[query.source];
    if (source == null ||
        source.record.type.id != query.typeId ||
        source.record.ref.kind == WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('not_found', '来源资料或模板已不可用。');
    }
    final rule = _relationRule(source.definition, query.key);
    if (rule == null) {
      throw const WorkspaceFailure('unsupported', '此资料没有该关联类型。');
    }
    final candidates = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : [
            for (final detail in _records.values)
              if (detail.record.ref != query.source &&
                  _acceptsRelation(rule, detail.record) &&
                  _matchesKeyword(detail.record, query.keyword))
                detail.record,
          ];
    candidates.sort((a, b) {
      final named = a.name.compareTo(b.name);
      return named != 0 ? named : a.ref.key.compareTo(b.ref.key);
    });
    final offset = _pageOffset(query.offset, query.limit, candidates.length);
    return WorkspaceResults(
      items: candidates.skip(offset).take(query.limit),
      total: candidates.length,
      offset: offset,
    );
  }

  Map<String, String> _relationErrors(
    WorkspaceRecordRef? source,
    Map<String, Object?> definition,
    Map<String, List<WorkspaceRecordRef>> changes,
  ) {
    final errors = <String, String>{};
    for (final entry in changes.entries) {
      final rule = _relationRule(definition, entry.key);
      if (rule == null) {
        errors['relation:${entry.key}'] = '关联类型已不可用。';
      } else if (entry.value.toSet().length != entry.value.length) {
        errors['relation:${entry.key}'] = '同一种关联不能重复选择同一份资料。';
      } else if (entry.value.any((ref) => ref == source)) {
        errors['relation:${entry.key}'] = '不能将资料关联到自身。';
      } else if (entry.value.any(
        (ref) =>
            _records[ref] == null || _scenario == SampleWorkspaceScenario.empty,
      )) {
        errors['relation:${entry.key}'] = '关联目标已不可用，请移除后重新选择。';
      } else if (entry.value.any(
        (ref) => !_acceptsRelation(rule, _records[ref]!.record),
      )) {
        errors['relation:${entry.key}'] = '所选资料类型不符合此关联要求。';
      }
    }
    return errors;
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
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    await _readable();
    return List.unmodifiable([
      if (_scenario != SampleWorkspaceScenario.empty)
        for (final ref in refs.toSet())
          if (_records[ref] case final detail?) detail.record,
    ]);
  }

  Map<String, String> _fieldErrors(
    String name,
    String description,
    Map<String, Object?> definition,
    Map<String, Object?> values,
  ) {
    final fields = <String, String>{};
    if (name.trim().isEmpty || name.length > 160) {
      fields['name'] = '请输入1–160字的名称。';
    }
    if (description.length > 2000) fields['description'] = '说明不能超过2000字。';
    for (final field in definition['fields'] as List? ?? []) {
      if (field['type'] != 'entries' &&
          values[field['key']] != null &&
          values[field['key']] is! String) {
        fields[field['key'] as String] = '此字段需要文本值，请勿用复合内容覆盖。';
        continue;
      }
      final text = values[field['key']]?.toString().trim() ?? '';
      if (field['required'] == true && text.isEmpty) {
        fields[field['key'] as String] = '请填写${field['label']}。';
      } else if (text.isNotEmpty &&
          field['type'] == 'number' &&
          (!RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?$').hasMatch(text) ||
              num.tryParse(text)?.isFinite != true)) {
        fields[field['key'] as String] = '请输入有限的十进制数字。';
      } else if (text.isNotEmpty && field['type'] == 'date') {
        final date = DateTime.tryParse(text);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
            date == null ||
            date.toIso8601String().substring(0, 10) != text) {
          fields[field['key'] as String] = '请输入有效日期（YYYY-MM-DD）。';
        }
      }
    }
    return fields;
  }

  @override
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft) async {
    try {
      await _readable();
    } on WorkspaceFailure catch (error) {
      return WorkspaceRejected(error);
    }
    final fingerprint = _fingerprint({
      'operation': 'create',
      'type': draft.typeId,
      'name': draft.name,
      'description': draft.description,
      'directory': draft.directoryId,
      'tags': draft.tagIds,
      'values': draft.values,
      'relations': {
        for (final entry in draft.relations.entries)
          entry.key: entry.value.map((r) => r.key).toList(),
      },
    });
    final previous = _operations[draft.operationId];
    if (previous != null) {
      return previous.fingerprint == fingerprint
          ? previous.result
          : const WorkspaceRejected(
              WorkspaceFailure('operation_conflict', '同一次保存不能用于不同内容。'),
            );
    }
    final prototype = _initial.values
        .where((d) => d.record.type.id == draft.typeId)
        .firstOrNull;
    final definition = draft.typeId == 'generic'
        ? _genericDefinition
        : prototype?.definition ?? <String, Object?>{};
    WorkspaceSaveResult result;
    final errors = _fieldErrors(
      draft.name,
      draft.description,
      definition,
      draft.values,
    );
    errors.addAll(_relationErrors(null, definition, draft.relations));
    if (draft.operationId.isEmpty ||
        prototype == null ||
        prototype.record.ref.kind == WorkspaceRecordKind.credential) {
      result = const WorkspaceRejected(
        WorkspaceFailure('unsupported', '请选择可创建的普通资料类型。'),
      );
    } else if (errors.isNotEmpty) {
      result = WorkspaceRejected(
        WorkspaceFailure('validation', '请检查标记的字段。', fieldErrors: errors),
      );
    } else if ((draft.directoryId != null &&
            !_catalog.directories.any(
              (d) =>
                  d.id == draft.directoryId &&
                  !['all', 'unfiled'].contains(d.id),
            )) ||
        draft.tagIds.any((id) => !_catalog.tags.any((t) => t.id == id))) {
      result = const WorkspaceRejected(
        WorkspaceFailure('validation', '目录或标签引用已失效。'),
      );
    } else if (nextSaveFailure != null) {
      result = WorkspaceRejected(nextSaveFailure!);
      nextSaveFailure = null;
    } else {
      final record = WorkspaceRecordSummary(
        ref: WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'preview-record-${++_nextRecord}',
        ),
        name: draft.name.trim(),
        description: draft.description,
        type: prototype.record.type,
        updatedAt: DateTime.utc(
          2026,
          10,
          26,
        ).add(Duration(microseconds: _clock++)),
        directoryId: draft.directoryId,
        tags: _catalog.tags.where((t) => draft.tagIds.contains(t.id)),
      );
      final detail = WorkspaceDetail(
        record: record,
        version: 1,
        definition: definition,
        values: draft.values,
        relations: draft.relations,
      );
      if (_scenario == SampleWorkspaceScenario.empty) {
        _records.clear();
        _scenario = SampleWorkspaceScenario.ready;
      }
      _versions[record.ref] = detail.version;
      _records[record.ref] = detail;
      _changes.add(record.ref);
      result = WorkspaceSaved(detail);
    }
    _operations[draft.operationId] = (fingerprint: fingerprint, result: result);
    return result;
  }

  @override
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) async {
    try {
      await _readable();
    } on WorkspaceFailure catch (failure) {
      return WorkspaceRejected(failure);
    }
    final fingerprint = _fingerprint({
      'target': edit.record.ref.key,
      'version': edit.expectedVersion,
      'name': edit.record.name,
      'description': edit.record.description,
      'type': edit.record.type.id,
      'directory': edit.record.directoryId,
      'tags': edit.record.tags.map((t) => t.id).toList(),
      'values': edit.values,
      'relations': {
        for (final entry in edit.relations.entries)
          entry.key: entry.value.map((r) => r.key).toList(),
      },
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
    final values = {...?current?.values, ...edit.values};
    final fields = _fieldErrors(
      edit.record.name,
      edit.record.description,
      current?.definition ?? {},
      values,
    );
    fields.addAll(
      _relationErrors(
        edit.record.ref,
        current?.definition ?? {},
        edit.relations,
      ),
    );
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
    } else if (edit.record.ref.kind == WorkspaceRecordKind.credential &&
        (edit.values.isNotEmpty || edit.relations.isNotEmpty)) {
      result = const WorkspaceRejected(
        WorkspaceFailure('unsupported', '凭据正文和关联不通过普通资料接口读写。'),
      );
    } else if (fields.isNotEmpty) {
      result = WorkspaceRejected(
        WorkspaceFailure('validation', '请检查标记的字段。', fieldErrors: fields),
      );
    } else if (edit.record.type.id != current.record.type.id ||
        (edit.record.directoryId != null &&
            !_catalog.directories.any(
              (d) =>
                  d.id == edit.record.directoryId &&
                  !['all', 'unfiled'].contains(d.id),
            )) ||
        edit.record.tags.any(
          (t) => !_catalog.tags.any((known) => known.id == t.id),
        )) {
      result = const WorkspaceRejected(
        WorkspaceFailure('validation', '类型、目录或标签引用已失效。'),
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
        relations: {...current.relations, ...edit.relations},
      );
      if (edit.record.ref.kind == WorkspaceRecordKind.information) {
        (_revisions[edit.record.ref] ??= []).add(_archive(current));
      }
      _versions[edit.record.ref] = detail.version;
      _records[edit.record.ref] = detail;
      _changes.add(edit.record.ref);
      result = WorkspaceSaved(detail);
    }
    _operations[edit.operationId] = (fingerprint: fingerprint, result: result);
    return result;
  }

  @override
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) =>
      _loadRevisions(ref);
  @override
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) => _previewRevision(ref, version, expectedVersion: expectedVersion);
  @override
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) => _queryRecycled(keyword: keyword, offset: offset, limit: limit);
  @override
  Future<WorkspaceArchive> readRecycled(String entryId) =>
      _readRecycled(entryId);
  @override
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange change) =>
      _changeRecord(change);

  void reset() {
    setScenario(SampleWorkspaceScenario.ready);
    _records
      ..clear()
      ..addAll(_initial);
    _operations.clear();
    _revisions.clear();
    _recycled.clear();
    _recordOperations.clear();
    _versions
      ..clear()
      ..addEntries(
        _initial.entries.map((e) => MapEntry(e.key, e.value.version)),
      );
    _nextRecycle = 0;
    _directoryOperations.clear();
    if (_initialCatalog case final initial?) _catalog = initial;
    _catalogVersion++;
    nextSaveFailure = null;
    _clock = 0;
    _nextRecord = 0;
    if (!_disposed) _changes.add(null);
  }

  void dispose() {
    _disposed = true;
    setScenario(SampleWorkspaceScenario.ready);
    unawaited(_changes.close());
  }
}
