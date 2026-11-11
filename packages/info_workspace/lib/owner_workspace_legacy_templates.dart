import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_source.dart';

/// Read retained definitions for existing records; there is no legacy creation
/// or conversion page. This projection never changes a stored definition.
class OwnerWorkspaceLegacyTemplates implements WorkspaceLegacyTemplateSource {
  OwnerWorkspaceLegacyTemplates(this.owner)
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
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
}
