import 'package:info_core/template_packages.dart' as core;
import 'workspace_plugins.dart';
import 'workspace_records.dart';

/// UI translation of the shared declarative validator. Never executes a package.
class TemplatePackageDecoder {
  static const maxBytes = core.DeclarativeTemplatePackageDecoder.maxBytes;
  static const maxDepth = core.DeclarativeTemplatePackageDecoder.maxDepth;
  static const fieldTypes = core.DeclarativeTemplatePackageDecoder.fieldTypes;
  static const icons = core.DeclarativeTemplatePackageDecoder.icons;
  WorkspacePlugin decode(
    List<int> bytes, {
    required String origin,
    Set<String> knownTemplates = const {},
    bool allowMissingTargets = false,
  }) {
    try {
      final p = core.DeclarativeTemplatePackageDecoder().decode(
        bytes,
        origin: origin,
        knownTemplates: knownTemplates,
        allowMissingTargets: allowMissingTargets,
      );
      return WorkspacePlugin(
        id: p.id,
        name: p.name,
        version: p.version,
        author: p.author,
        description: p.description,
        digest: p.digest,
        origin: p.origin,
        templates: p.templates.map(
          (t) => WorkspacePluginTemplate(
            id: t.id,
            type: WorkspaceType(t.type.id, t.type.name, t.type.icon),
            definition: t.definition,
          ),
        ),
      );
    } on core.TemplatePackageFailure catch (e) {
      throw WorkspaceFailure(
        'invalid_package',
        '插件包格式不受支持。',
        fieldErrors: e.fieldErrors,
      );
    }
  }
}
