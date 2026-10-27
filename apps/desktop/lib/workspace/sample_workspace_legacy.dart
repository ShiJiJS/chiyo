import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_source.dart';
import 'sample_workspace_plugins.dart';

const sampleLegacyInputs = [
  (
    id: 'legacy-resource',
    name: '资源登记',
    description: '记录资源入口、用途和维护约定。',
    fields: [
      WorkspaceLegacyField(
        'legacy-resource-url',
        '访问入口',
        '填写完整链接；不要写入登录凭据。',
        WorkspaceLegacyFieldKind.structured,
      ),
      WorkspaceLegacyField(
        'legacy-resource-note',
        '维护说明',
        '用途、维护责任及去重依据。',
        WorkspaceLegacyFieldKind.textNote,
      ),
    ],
  ),
  (
    id: 'legacy-handover',
    name: '文件交接',
    description: '交接说明与一份普通附件。',
    fields: [
      WorkspaceLegacyField(
        'legacy-handover-note',
        '交接说明',
        '说明附件用途和包含的内容类别。',
        WorkspaceLegacyFieldKind.textNote,
      ),
      WorkspaceLegacyField(
        'legacy-handover-file',
        '交接附件',
        '选择需保管的普通文件，不用于托管凭据。',
        WorkspaceLegacyFieldKind.file,
      ),
    ],
  ),
];
typedef SampleLegacyInput = ({
  String id,
  String name,
  String description,
  List<WorkspaceLegacyField> fields,
});

class SampleWorkspaceLegacy implements WorkspaceLegacyTemplateSource {
  SampleWorkspaceLegacy({
    required this.readable,
    required this.changed,
    required this.plugins,
    Iterable<SampleLegacyInput> inputs = sampleLegacyInputs,
  }) {
    for (final i in inputs) {
      final value = _project(i.id, i.name, i.description, 1, i.fields);
      _initial[i.id] = _current[i.id] = value;
    }
  }
  final Future<void> Function() readable;
  final void Function() changed;
  final SampleWorkspacePlugins plugins;
  final _initial = <String, WorkspaceLegacyTemplate>{},
      _current = <String, WorkspaceLegacyTemplate>{};
  Map<String, WorkspaceLegacyTemplate> capturePortable() =>
      Map.unmodifiable(_current);
  void installPortable(Map<String, WorkspaceLegacyTemplate> values) {
    _current
      ..clear()
      ..addAll(values);
  }

  String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
  WorkspaceLegacyTemplate _project(
    String id,
    String name,
    String description,
    int version,
    List<WorkspaceLegacyField> fields,
  ) {
    if (id.isEmpty ||
        name.trim().isEmpty ||
        name.length > 200 ||
        description.length > 2000 ||
        fields.isEmpty ||
        fields.length > 200 ||
        fields.any(
          (f) =>
              f.id.isEmpty ||
              f.name.trim().isEmpty ||
              f.name.length > 200 ||
              f.description.length > 2000,
        ) ||
        fields.map((f) => f.id).toSet().length != fields.length) {
      throw const FormatException(
        'Invalid legacy fixture identity or field budget.',
      );
    }
    final keys = {
      for (final f in fields) 'field_${_hash(f.id).substring(0, 32)}': f.id,
    };
    final descriptor = [
      for (final f in fields)
        {
          'key': keys.keys.singleWhere((key) => keys[key] == f.id),
          'label': f.name,
          'description': f.description,
          'type': switch (f.kind) {
            WorkspaceLegacyFieldKind.structured => 'text',
            WorkspaceLegacyFieldKind.textNote => 'multiline',
            WorkspaceLegacyFieldKind.file => 'file',
          },
        },
    ];
    return WorkspaceLegacyTemplate(
      id: id,
      name: name,
      description: description,
      version: version,
      fields: fields,
      packageId: 'local.legacy.p${_hash(id).substring(0, 24)}',
      conversionProblem:
          fields.any((f) => f.kind == WorkspaceLegacyFieldKind.file)
          ? '当前声明包格式不支持普通附件字段，不能转换此模板；旧版录入仍可继续使用。'
          : fields.length > 40
          ? '当前声明包每个模板最多40个字段，不能截断转换；旧版录入仍可继续使用。'
          : null,
      definition: {
        'name': name,
        'fields': descriptor,
        'sections': [
          {'kind': 'fields', 'title': name, 'keys': keys.keys.toList()},
        ],
        'legacyTemplateId': id,
        'legacyTemplateVersion': version,
        'legacyDefinitionIds': keys,
      },
    );
  }

  WorkspaceLegacyTemplate current(String id) =>
      _current[id] ??
      (throw const WorkspaceFailure('not_found', '旧版模板已不存在，请重新读取。'));
  @override
  Future<List<WorkspaceLegacyTemplate>> load() async {
    await readable();
    return List.unmodifiable(_current.values);
  }

  @override
  Future<WorkspaceLegacyTemplate> read(String id) async {
    await readable();
    return current(id);
  }

  @override
  Future<WorkspacePluginCandidate> prepareConversion(
    String id,
    int expectedVersion,
  ) async {
    await readable();
    final template = current(id);
    if (template.version != expectedVersion) {
      throw const WorkspaceFailure('conflict', '旧版模板已变化，请重新读取并核对。');
    }
    if (template.conversionProblem case final reason?) {
      throw WorkspaceFailure('conversion_unsupported', reason);
    }
    final fields = [
      for (final f in template.definition['fields'] as List)
        {
          'key': f['key'],
          'label': f['label'],
          'type': f['type'],
          'required': false,
        },
    ];
    final package = {
      'id': template.packageId,
      'name': template.name,
      'version': '1.${template.version}.0',
      'hostApi': 1,
      'author': '旧版模板转换',
      'description': template.description,
      'templates': [
        {
          'id': 'record',
          'name': template.name,
          'icon': 'file',
          'fields': fields,
          'sections': template.definition['sections'],
          'relations': <Object?>[],
          'instructions': [
            '先核对字段含义。模板不授予信息访问或凭据使用许可。',
            for (final f in template.fields) '${f.name}：${f.description}',
          ].join('\n'),
        },
      ],
    };
    final provenance = {
      'templateId': template.id,
      'version': template.version,
      'definitionIds': template.definition['legacyDefinitionIds'],
    };
    return plugins.stageLegacyConversion(
      '旧版模板-${_hash(id).substring(0, 12)}.json',
      utf8.encode(jsonEncode(package)),
      provenance,
      () {
        if (current(id).version != expectedVersion) {
          throw const WorkspaceFailure('conflict', '旧版模板已变化，请重新预览转换结果。');
        }
      },
    );
  }

  void reset() {
    _current
      ..clear()
      ..addAll(_initial);
  }

  /// Composition-only concurrent-editor fixture; normal metadata APIs stay read-only.
  void revise(String id) {
    final t = current(id), version = t.version + 1;
    _current[id] = _project(t.id, t.name, t.description, version, [
      for (final (index, f) in t.fields.indexed)
        index == 0
            ? WorkspaceLegacyField(
                '${f.id}:$version',
                f.name,
                '更新后的字段说明。',
                f.kind,
              )
            : f,
    ]);
    changed();
  }
}
