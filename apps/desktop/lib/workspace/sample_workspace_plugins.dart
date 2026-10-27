import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';
import 'workspace_operation.dart';
import 'workspace_plugins.dart';
import 'template_package_decoder.dart';

/// Owns only resettable package definitions. Record snapshots stay with records.
class SampleWorkspacePlugins implements WorkspacePluginSource {
  SampleWorkspacePlugins({
    required this.readable,
    required this.beforeWrite,
    required this.changed,
    required this.recordCounts,
    required this.inputs,
  });
  final Future<void> Function() readable;
  final void Function() beforeWrite, changed;
  final Map<String, int> Function() recordCounts;
  final Map<String, ({String filename, List<int> bytes})> inputs;
  final _selections = <String, ({String filename, List<int> bytes})>{};
  final _legacySelections =
      <String, ({Map<String, Object?> source, void Function() validate})>{};
  WorkspacePluginCandidate stageLegacyConversion(
    String filename,
    List<int> bytes,
    Map<String, Object?> source,
    void Function() validate,
  ) {
    if (_selections.length >= 100) {
      throw const WorkspaceFailure('selection_busy', '待核对的选择过多，请先关闭已有表单。');
    }
    final candidate = _stage((filename: filename, bytes: bytes));
    _legacySelections[candidate.selectionId] = (
      source: workspaceImmutableMap(source),
      validate: validate,
    );
    return candidate;
  }

  final _current = <String, WorkspacePlugin>{},
      _initial = <String, WorkspacePlugin>{};
  final _knownTypes = <String, WorkspaceType>{};
  final _operations =
      <String, ({String fingerprint, WorkspacePluginReceipt receipt})>{};
  int _version = 1;
  int get version => _version;
  bool loseNextReply = false;

  void seed(Iterable<WorkspaceDetail> records) {
    final definitions = <String, WorkspaceDetail>{};
    for (final detail in records) {
      if (const {
        'server',
        'service',
        'profile',
      }.contains(detail.record.type.id)) {
        definitions.putIfAbsent(detail.record.type.id, () => detail);
      }
    }
    const descriptions = {
      'server': '连接参数、维护文档与登录凭据，一处查找。',
      'service': '记录访问入口、用途及可选的部署关系。',
      'profile': '按经历组织个人资料，关联简历与证明。',
    };
    for (final (key, detail) in definitions.entries.map(
      (e) => (e.key, e.value),
    )) {
      final id = 'builtin.$key',
          digest = sha256
              .convert(utf8.encode(jsonEncode(detail.definition)))
              .toString();
      final template = WorkspacePluginTemplate(
        id: key,
        type: detail.record.type,
        definition: {
          ...detail.definition,
          'packageId': id,
          'templateVersion': '1.0.0',
          'packageDigest': digest,
        },
      );
      final package = WorkspacePlugin(
        id: id,
        name: detail.record.type.name,
        version: '1.0.0',
        author: '知予',
        description: descriptions[key]!,
        digest: digest,
        origin: '内置',
        templates: [template],
        builtin: true,
        panels: key == 'server' ? [WorkspacePluginPanel.sshTrust] : const [],
      );
      _initial[id] = _current[id] = package;
      _knownTypes[template.type.id] = template.type;
    }
  }

  void clear() {
    _legacySelections.clear();
    _selections.clear();
    _current.clear();
    _initial.clear();
    _knownTypes.clear();
    _operations.clear();
    _version++;
    loseNextReply = false;
  }

  void reset() {
    _legacySelections.clear();
    _selections.clear();
    _current
      ..clear()
      ..addAll(_initial);
    _knownTypes
      ..clear()
      ..addEntries(
        _initial.values
            .expand((p) => p.templates)
            .map((t) => MapEntry(t.type.id, t.type)),
      );
    _operations.clear();
    _version++;
    loseNextReply = false;
  }

  Iterable<WorkspaceType> get knownTypes => _knownTypes.values;
  WorkspacePlugin? forType(String typeId) => _current.values
      .where((p) => p.templates.any((t) => t.type.id == typeId))
      .firstOrNull;
  WorkspaceTemplateState stateFor(String typeId, String packageId) {
    final package = _current[packageId];
    if (package == null) return WorkspaceTemplateState.missing;
    if (!package.enabled) return WorkspaceTemplateState.disabled;
    if (!package.templates.any((t) => t.type.id == typeId)) {
      return WorkspaceTemplateState.removedDefinition;
    }
    return WorkspaceTemplateState.available;
  }

  bool available(String typeId) =>
      !_knownTypes.containsKey(typeId) || (forType(typeId)?.enabled ?? false);
  WorkspacePluginTemplate? template(String typeId) => _current.values
      .where((p) => p.enabled)
      .expand((p) => p.templates)
      .where((t) => t.type.id == typeId)
      .firstOrNull;
  WorkspacePlugin _project(WorkspacePlugin p) =>
      p.project(affectedRecords: recordCounts()[p.id] ?? 0);

  Future<List<WorkspacePluginCandidate>> choices() async {
    await readable();
    if (_selections.length + inputs.length > 100) {
      throw const WorkspaceFailure('selection_busy', '待核对的选择过多，请先关闭已有表单。');
    }
    return [for (final e in inputs.entries) _stage(e.value)];
  }

  WorkspacePluginCandidate _stage(({String filename, List<int> bytes}) input) {
    final id = workspaceOperationId();
    _selections[id] = (
      filename: input.filename,
      bytes: List.unmodifiable(input.bytes),
    );
    return WorkspacePluginCandidate(id, input.filename, input.bytes.length);
  }

  @override
  Future<void> releaseCandidate(String selectionId) async {
    _selections.remove(selectionId);
    _legacySelections.remove(selectionId);
  }

  @override
  Future<WorkspacePluginCatalog> load() async {
    await readable();
    return WorkspacePluginCatalog(_version, _current.values.map(_project));
  }

  WorkspacePlugin _decode(String selectionId) {
    final input = _selections[selectionId];
    if (input == null) {
      throw const WorkspaceFailure('selection_unavailable', '所选插件包已不可用，请重新选择。');
    }
    final legacy = _legacySelections[selectionId];
    legacy?.validate();
    final decoded = TemplatePackageDecoder().decode(
      input.bytes,
      origin: input.filename,
      knownTemplates: {
        for (final p in _current.values)
          for (final t in p.templates) '${p.id}/${t.id}',
      },
    );
    return legacy == null ? decoded : decoded.fromLegacy(legacy.source);
  }

  int _compareVersions(String a, String b) {
    final left = a.split('.'), right = b.split('.');
    for (var i = 0; i < 3; i++) {
      final compared = BigInt.parse(left[i]).compareTo(BigInt.parse(right[i]));
      if (compared != 0) return compared;
    }
    return 0;
  }

  void _checkVersion(WorkspacePlugin next, WorkspacePlugin? previous) {
    if (previous == null) return;
    final compared = _compareVersions(next.version, previous.version);
    if (compared == 0 && next.digest != previous.digest) {
      throw const WorkspaceFailure(
        'package_version_conflict',
        '同一版本的内容摘要不同，不能覆盖已安装包。',
      );
    }
    if (compared == 0) {
      throw const WorkspaceFailure('already_installed', '同一版本与摘要已安装，无需重复安装。');
    }
    // A different content shape is a new definition identity, not a relabeling
    // of an existing key. Instance snapshots never follow this mutable catalog.
    for (final t in next.templates) {
      final old = previous.templates.where((old) => old.id == t.id).firstOrNull;
      if (old == null) continue;
      final kinds = {
        for (final f in old.definition['fields'] as List) f['key']: f['type'],
      };
      for (final field in t.definition['fields'] as List) {
        if (kinds.containsKey(field['key']) &&
            kinds[field['key']] != field['type']) {
          throw WorkspaceFailure(
            'definition_identity_conflict',
            '字段内容形态改变时须使用新的定义身份。',
            fieldErrors: {'${t.id}.${field['key']}': '不能以相同字段key改变原内容形态。'},
          );
        }
      }
    }
  }

  List<String> _differences(WorkspacePlugin next, WorkspacePlugin? old) {
    if (old == null) return ['新增${next.templates.length}个模板，仅用于后续新建。'];
    final changes = <String>[];
    if (next.name != old.name) changes.add('包名称：${old.name} → ${next.name}');
    if (next.author != old.author) {
      changes.add('作者自述：${old.author} → ${next.author}');
    }
    if (next.description != old.description) {
      changes.add('用途说明：${old.description} → ${next.description}');
    }
    if (_compareVersions(next.version, old.version) < 0) {
      changes.add('将安装较早版本，仅改变后续新建；已有资料不会回退。');
    }
    final oldTemplates = {for (final t in old.templates) t.id: t};
    for (final t in next.templates) {
      final before = oldTemplates[t.id];
      if (before == null) {
        changes.add('新增模板：${t.type.name}');
        continue;
      }
      if (before.type.name != t.type.name) {
        changes.add('模板名称：${before.type.name} → ${t.type.name}');
      }
      if (before.type.icon != t.type.icon) {
        changes.add('模板图标：${before.type.icon} → ${t.type.icon}');
      }
      final fields = {
        for (final f in before.definition['fields'] as List) f['key']: f,
      };
      final newFields = t.definition['fields'] as List;
      for (final field in newFields) {
        final oldField = fields[field['key']];
        if (oldField == null) {
          changes.add('新增字段：${field['label']}');
        } else if (jsonEncode(oldField) != jsonEncode(field)) {
          changes.add(
            '字段${field['key']}：${oldField['label']}（${oldField['required'] == true ? '必填' : '选填'}） → ${field['label']}（${field['required'] == true ? '必填' : '选填'}），仅用于新建',
          );
        }
      }
      for (final f in fields.values) {
        if (!newFields.any((n) => n['key'] == f['key'])) {
          changes.add('新定义移除字段：${f['label']}（旧资料保留）');
        }
      }
      for (final key in ['sections', 'relations', 'instructions']) {
        if (jsonEncode(before.definition[key]) !=
            jsonEncode(t.definition[key])) {
          changes.add(
            '${t.type.name}的${switch (key) {
              'sections' => '阅读章节',
              'relations' => '关联定义',
              _ => '录入说明',
            }}变化',
          );
        }
      }
    }
    for (final t in old.templates) {
      if (!next.templates.any((n) => n.id == t.id)) {
        changes.add('新包移除模板：${t.type.name}（旧资料保留）');
      }
    }
    if (changes.isEmpty) changes.add('包元数据或来源摘要变化。');
    return changes;
  }

  @override
  Future<WorkspacePluginPreview> previewInstall(String selectionId) async {
    await readable();
    final next = _decode(selectionId), previous = _current[next.id];
    _checkVersion(next, previous);
    return WorkspacePluginPreview(
      selectionId: selectionId,
      package: _project(next),
      previous: previous == null ? null : _project(previous),
      catalogVersion: _version,
      differences: _differences(next, previous),
    );
  }

  @override
  Future<WorkspacePluginReceipt> change(WorkspacePluginChange command) async {
    await readable();
    if (command.operationId.trim().isEmpty) {
      throw const WorkspaceFailure('validation', '操作身份不能为空。');
    }
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              command.action.name,
              command.packageId,
              command.expectedVersion,
              command.selectionId,
              command.expectedDigest,
            ]),
          ),
        )
        .toString();
    final prior = _operations[command.operationId];
    if (prior != null) {
      if (prior.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return prior.receipt;
    }
    if (command.expectedVersion != _version) {
      throw const WorkspaceFailure('conflict', '插件目录已变化，请重新读取并核对影响。');
    }
    final previous = _current[command.packageId];
    WorkspacePlugin? next;
    if (command.action == WorkspacePluginAction.install) {
      next = _decode(command.selectionId ?? '');
      if (next.id != command.packageId ||
          next.digest != command.expectedDigest) {
        throw const WorkspaceFailure('conflict', '插件来源或内容已变化，请重新预览。');
      }
      _checkVersion(next, previous);
      if (previous != null) next = next.project(enabled: previous.enabled);
    } else {
      if (previous == null) {
        throw const WorkspaceFailure('not_found', '插件已移除，请重新读取。');
      }
      if (command.expectedDigest != previous.digest) {
        throw const WorkspaceFailure('conflict', '插件内容已变化，请重新读取。');
      }
      if (command.action == WorkspacePluginAction.remove && previous.builtin) {
        throw const WorkspaceFailure('unsupported', '内置插件可停用，不能移除。');
      }
      if (command.action != WorkspacePluginAction.remove) {
        next = previous.project(
          enabled: command.action == WorkspacePluginAction.enable,
        );
      }
    }
    beforeWrite();
    // No awaits from here: definition state and the content-free fact commit
    // together. Neither install nor removal edits any existing record snapshot.
    if (next == null) {
      _current.remove(command.packageId);
    } else {
      _current[next.id] = next;
      for (final t in next.templates) {
        _knownTypes[t.type.id] = t.type;
      }
    }
    final receipt = WorkspacePluginReceipt(
      operationId: command.operationId,
      action: command.action,
      packageId: command.packageId,
      expectedVersion: command.expectedVersion,
      version: ++_version,
      digest: next?.digest,
    );
    _operations[command.operationId] = (
      fingerprint: fingerprint,
      receipt: receipt,
    );
    changed();
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对结果。');
    }
    return receipt;
  }

  @override
  Future<WorkspacePluginReceipt?> receipt(String operationId) async {
    await readable();
    return _operations[operationId]?.receipt;
  }
}
