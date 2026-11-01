import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_plugins.dart';
import 'workspace_source.dart';

/// Actual retained definitions, including a genuine empty catalog. Conversion
/// stages a declarative candidate; it neither installs nor rewrites records.
class OwnerWorkspaceLegacyTemplates implements WorkspaceLegacyTemplateSource {
  OwnerWorkspaceLegacyTemplates(this.owner, this.plugins)
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final OwnerWorkspacePlugins plugins;
  final core.OwnerLibraryScope _scope;
  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  Future<T> _run<T>(Future<T> Function() action) =>
      owner.inLibraryScope(_scope, action);
  static WorkspaceLegacyTemplate project(core.InformationTemplate t) {
    final fields = [
      for (final f in t.fields)
        WorkspaceLegacyField(
          f.id,
          f.name,
          f.description,
          WorkspaceLegacyFieldKind.values.byName(f.kind.name),
        ),
    ];
    final ids = {
      for (final f in fields) 'field_${_hash(f.id).substring(0, 32)}': f.id,
    };
    return WorkspaceLegacyTemplate(
      id: t.id,
      name: t.name,
      description: t.description,
      version: t.version,
      fields: fields,
      packageId: 'local.legacy.p${_hash(t.id).substring(0, 24)}',
      conversionProblem:
          fields.any((f) => f.kind == WorkspaceLegacyFieldKind.file)
          ? '当前声明包不支持普通附件字段，不能截断转换；原模板和已有资料保留。'
          : fields.length > 40
          ? '当前声明包最多40个字段，不能截断转换；原模板和已有资料保留。'
          : null,
      definition: {
        'id': 'generic',
        'name': t.name,
        'fields': [
          for (final f in fields)
            {
              'key': ids.keys.singleWhere((k) => ids[k] == f.id),
              'label': f.name,
              'description': f.description,
              'type': switch (f.kind) {
                WorkspaceLegacyFieldKind.structured => 'text',
                WorkspaceLegacyFieldKind.textNote => 'multiline',
                WorkspaceLegacyFieldKind.file => 'file',
              },
            },
        ],
        'sections': [
          {'kind': 'fields', 'title': t.name, 'keys': ids.keys.toList()},
        ],
        'legacyTemplateId': t.id,
        'legacyTemplateVersion': t.version,
        'legacyDefinitionIds': ids,
      },
    );
  }

  WorkspaceLegacyTemplate _read(String id) {
    final t = owner.templates.where((t) => t.id == id).firstOrNull;
    if (t == null) throw const WorkspaceFailure('not_found', '旧版模板已不存在。');
    return project(t);
  }

  @override
  Future<List<WorkspaceLegacyTemplate>> load() =>
      _run(() async => owner.templates.map(project).toList());
  @override
  Future<WorkspaceLegacyTemplate> read(String id) =>
      _run(() async => _read(id));
  @override
  Future<WorkspacePluginCandidate> prepareConversion(
    String id,
    int expectedVersion,
  ) => _run(() async {
    final t = _read(id);
    if (t.version != expectedVersion) {
      throw const WorkspaceFailure('conflict', '原模板已变化，请重新读取。');
    }
    if (t.conversionProblem != null) {
      throw WorkspaceFailure('conversion_unsupported', t.conversionProblem!);
    }
    final input = {
      'id': t.packageId,
      'name': t.name,
      'version': '1.${t.version}.0',
      'hostApi': 1,
      'author': '旧版模板转换',
      'description': t.description,
      'templates': [
        {
          'id': 'record',
          'name': t.name,
          'icon': 'file',
          'fields': [
            for (final f in t.definition['fields'] as List)
              {
                'key': f['key'],
                'label': f['label'],
                'type': f['type'],
                'required': false,
              },
          ],
          'sections': t.definition['sections'],
          'relations': <Object?>[],
          'instructions': [
            for (final f in t.fields) '${f.name}：${f.description}',
          ].join('\n'),
        },
      ],
    };
    return plugins.stageLegacy(
      '旧版模板-${_hash(id).substring(0, 12)}.json',
      utf8.encode(jsonEncode(input)),
      {
        'templateId': id,
        'version': t.version,
        'definitionIds': t.definition['legacyDefinitionIds'],
      },
      () {
        if (_read(id).version != expectedVersion) {
          throw const WorkspaceFailure('conflict', '旧版模板已变化，请重新预览转换。');
        }
      },
    );
  });
}
