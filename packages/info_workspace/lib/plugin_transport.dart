import 'workspace_plugins.dart';
import 'workspace_records.dart';

// Shared typed wire representation. Packages remain declarative definitions;
// no native selection path or executable settings callback crosses the wire.
Map<String, Object?> pluginToJson(WorkspacePlugin p) => {
  'id': p.id,
  'name': p.name,
  'version': p.version,
  'author': p.author,
  'description': p.description,
  'digest': p.digest,
  'origin': p.origin,
  'builtin': p.builtin,
  'enabled': p.enabled,
  'affectedRecords': p.affectedRecords,
  'panels': p.panels.map((e) => e.name).toList(),
  if (p.legacySource != null) 'legacySource': p.legacySource,
  'templates': [
    for (final t in p.templates)
      {
        'id': t.id,
        'type': {'id': t.type.id, 'name': t.type.name, 'icon': t.type.icon},
        'definition': t.definition,
      },
  ],
};

WorkspacePlugin pluginFromJson(Map<String, dynamic> p) {
  final id = p['id'] as String;
  final builtin = p['builtin'] as bool;
  final panels = [
    for (final panel in p['panels'] as List)
      WorkspacePluginPanel.values.byName(panel as String),
  ];
  if (panels.isNotEmpty && (!builtin || id != 'builtin.server')) {
    throw const FormatException('Unsupported plugin settings');
  }
  return WorkspacePlugin(
    id: id,
    name: p['name'] as String,
    version: p['version'] as String,
    author: p['author'] as String,
    description: p['description'] as String,
    digest: p['digest'] as String,
    origin: p['origin'] as String,
    builtin: builtin,
    enabled: p['enabled'] as bool,
    affectedRecords: p['affectedRecords'] as int,
    panels: panels,
    legacySource: (p['legacySource'] as Map?)?.cast<String, Object?>(),
    templates: [
      for (final t in p['templates'] as List)
        WorkspacePluginTemplate(
          id: t['id'] as String,
          type: WorkspaceType(
            t['type']['id'] as String,
            t['type']['name'] as String,
            t['type']['icon'] as String,
          ),
          definition: (t['definition'] as Map).cast<String, Object?>(),
        ),
    ],
  );
}

Map<String, Object?> pluginCatalogToJson(WorkspacePluginCatalog c) => {
  'version': c.version,
  'packages': c.packages.map(pluginToJson).toList(),
  'updates': [
    for (final u in c.updates)
      {
        'packageId': u.packageId,
        'version': u.version,
        'digest': u.digest,
        'installedDigest': u.installedDigest,
        'summary': u.summary,
      },
  ],
};

WorkspacePluginCatalog pluginCatalogFromJson(
  Map<String, dynamic> c,
) => WorkspacePluginCatalog(
  c['version'] as int,
  [for (final p in c['packages'] as List) pluginFromJson(Map.from(p as Map))],
  updates: [
    for (final u in c['updates'] as List)
      WorkspacePluginUpdate(
        packageId: u['packageId'] as String,
        version: u['version'] as String,
        digest: u['digest'] as String,
        installedDigest: u['installedDigest'] as String,
        summary: u['summary'] as String,
      ),
  ],
);

Map<String, Object?> pluginPreviewToJson(WorkspacePluginPreview p) => {
  'selectionId': p.selectionId,
  'package': pluginToJson(p.package),
  'previous': p.previous == null ? null : pluginToJson(p.previous!),
  'catalogVersion': p.catalogVersion,
  'differences': p.differences,
};

WorkspacePluginPreview pluginPreviewFromJson(Map<String, dynamic> p) =>
    WorkspacePluginPreview(
      selectionId: p['selectionId'] as String,
      package: pluginFromJson(Map.from(p['package'] as Map)),
      previous: p['previous'] == null
          ? null
          : pluginFromJson(Map.from(p['previous'] as Map)),
      catalogVersion: p['catalogVersion'] as int,
      differences: (p['differences'] as List).cast<String>(),
    );

Map<String, Object?> pluginChangeToJson(WorkspacePluginChange c) => {
  'operationId': c.operationId,
  'action': c.action.name,
  'packageId': c.packageId,
  'expectedVersion': c.expectedVersion,
  'selectionId': c.selectionId,
  'expectedDigest': c.expectedDigest,
};

WorkspacePluginChange pluginChangeFromJson(Map<String, dynamic> c) {
  if (c.keys.any(
    (k) => !const {
      'operationId',
      'action',
      'packageId',
      'expectedVersion',
      'selectionId',
      'expectedDigest',
    }.contains(k),
  )) {
    throw const FormatException('Invalid package change');
  }
  return WorkspacePluginChange(
    operationId: c['operationId'] as String,
    action:
        WorkspacePluginAction.values
            .where((a) => a.name == c['action'])
            .firstOrNull ??
        (throw const FormatException('Invalid package action')),
    packageId: c['packageId'] as String,
    expectedVersion: c['expectedVersion'] as int,
    selectionId: c['selectionId'] as String?,
    expectedDigest: c['expectedDigest'] as String?,
  );
}

Map<String, Object?> pluginReceiptToJson(WorkspacePluginReceipt r) => {
  'operationId': r.operationId,
  'action': r.action.name,
  'packageId': r.packageId,
  'expectedVersion': r.expectedVersion,
  'version': r.version,
  'digest': r.digest,
};

WorkspacePluginReceipt pluginReceiptFromJson(Map<String, dynamic> r) =>
    WorkspacePluginReceipt(
      operationId: r['operationId'] as String,
      action: WorkspacePluginAction.values.byName(r['action'] as String),
      packageId: r['packageId'] as String,
      expectedVersion: r['expectedVersion'] as int,
      version: r['version'] as int,
      digest: r['digest'] as String?,
    );
