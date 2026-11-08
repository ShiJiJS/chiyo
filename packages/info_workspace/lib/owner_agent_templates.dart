import 'package:info_core/info_core.dart' as core;
import 'package:info_core/builtin_information_definitions.dart';
import 'owner_workspace_template_packages.dart';
import 'builtin_credential_templates.dart';

/// Read the same installed-package projection as the owner UI. No origin path,
/// affected-record count, selection, private body or pending proposal is sent.
core.InformationTemplateCatalog currentAgentTemplates(core.OwnerAccess owner) {
  final plugins = OwnerWorkspaceTemplatePackages(owner: owner, changed: () {});
  try {
    final installed = plugins.packages;
    return core.InformationTemplateCatalog(
      version: owner.templatePackageVersion,
      plugins: [
        for (final p in installed)
          core.InformationPluginDescription(
            id: p.id,
            name: p.name,
            version: p.version,
            enabled: p.enabled,
            builtin: p.builtin,
            description: p.description,
            templateIds: [for (final t in p.templates) t.type.id],
          ),
      ],
      templates: [
        ...builtinCredentialTemplates(),
        for (final e in builtinWorkspaceDefinitions.entries)
          if (!const {'server', 'service', 'profile'}.contains(e.key))
            core.InformationTemplateDescription(
              id: e.key,
              name: e.value['name'] as String,
              version: e.value['templateVersion'] as String,
              digest: e.value['packageDigest'] as String,
              enabled: true,
              definition: e.value,
            ),
        for (final p in installed)
          for (final t in p.templates)
            core.InformationTemplateDescription(
              id: t.type.id,
              packageId: p.id,
              name: t.type.name,
              version: t.definition['templateVersion'] as String,
              digest: t.definition['packageDigest'] as String,
              enabled: p.enabled,
              definition: {...t.definition, 'id': t.type.id},
            ),
      ],
    );
  } finally {
    plugins.dispose();
  }
}
