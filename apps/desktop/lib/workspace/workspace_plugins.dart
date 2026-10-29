import 'workspace_records.dart';

/// Stable scoped template IDs; the three existing host types retain their IDs.
String workspaceTemplateTypeId(String package, String template) =>
    package == 'builtin.$template' &&
        const {'server', 'service', 'profile'}.contains(template)
    ? template
    : '$package/$template';

class WorkspacePluginTemplate {
  WorkspacePluginTemplate({
    required this.id,
    required this.type,
    required Map<String, Object?> definition,
  }) : definition = workspaceImmutableMap(definition);
  final String id;
  final WorkspaceType type;
  final Map<String, Object?> definition;
}

enum WorkspacePluginPanel { sshTrust }

class WorkspacePlugin {
  WorkspacePlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.digest,
    required this.origin,
    required Iterable<WorkspacePluginTemplate> templates,
    this.enabled = true,
    this.builtin = false,
    this.affectedRecords = 0,
    Iterable<WorkspacePluginPanel> panels = const [],
    Map<String, Object?>? legacySource,
  }) : templates = List.unmodifiable(templates),
       panels = Set.unmodifiable(panels),
       legacySource = legacySource == null
           ? null
           : workspaceImmutableMap(legacySource);
  final String id, name, version, author, description, digest, origin;
  final List<WorkspacePluginTemplate> templates;

  /// Registered by the host, never decoded from external package JSON.
  final Set<WorkspacePluginPanel> panels;
  final bool enabled, builtin;
  final int affectedRecords;
  final Map<String, Object?>? legacySource;
  WorkspacePlugin project({bool? enabled, int? affectedRecords}) =>
      WorkspacePlugin(
        id: id,
        name: name,
        version: version,
        author: author,
        description: description,
        digest: digest,
        origin: origin,
        templates: templates,
        enabled: enabled ?? this.enabled,
        builtin: builtin,
        panels: panels,
        affectedRecords: affectedRecords ?? this.affectedRecords,
        legacySource: legacySource,
      );
  WorkspacePlugin fromLegacy(Map<String, Object?> source) => WorkspacePlugin(
    id: id,
    name: name,
    version: version,
    author: author,
    description: description,
    digest: digest,
    origin: origin,
    enabled: enabled,
    builtin: builtin,
    panels: panels,
    affectedRecords: affectedRecords,
    legacySource: source,
    templates: [
      for (final t in templates)
        WorkspacePluginTemplate(
          id: t.id,
          type: t.type,
          definition: {...t.definition, 'legacySource': source},
        ),
    ],
  );
}

class WorkspacePluginCatalog {
  WorkspacePluginCatalog(
    this.version,
    Iterable<WorkspacePlugin> packages, {
    Iterable<WorkspacePluginUpdate> updates = const [],
  }) : packages = List.unmodifiable(packages),
       updates = List.unmodifiable(updates);
  final int version;
  final List<WorkspacePlugin> packages;
  final List<WorkspacePluginUpdate> updates;
}

/// An offer from the host's bundled catalog, not an external JSON assertion.
class WorkspacePluginUpdate {
  const WorkspacePluginUpdate({
    required this.packageId,
    required this.version,
    required this.digest,
    required this.installedDigest,
    required this.summary,
  });
  final String packageId, version, digest, installedDigest, summary;
}

/// Opaque host selection, never a path or executable capability.
class WorkspacePluginCandidate {
  const WorkspacePluginCandidate(
    this.selectionId,
    this.filename,
    this.byteLength,
  );
  final String selectionId, filename;
  final int byteLength;
}

typedef WorkspacePluginPicker = Future<WorkspacePluginCandidate?> Function();

class WorkspacePluginPreview {
  WorkspacePluginPreview({
    required this.selectionId,
    required this.package,
    required this.catalogVersion,
    this.previous,
    Iterable<String> differences = const [],
  }) : differences = List.unmodifiable(differences);
  final String selectionId;
  final WorkspacePlugin package;
  final WorkspacePlugin? previous;
  final int catalogVersion;
  final List<String> differences;
}

enum WorkspacePluginAction { install, enable, disable, remove }

class WorkspacePluginChange {
  const WorkspacePluginChange({
    required this.operationId,
    required this.action,
    required this.packageId,
    required this.expectedVersion,
    this.selectionId,
    this.expectedDigest,
  });
  final String operationId, packageId;
  final WorkspacePluginAction action;
  final int expectedVersion;
  final String? selectionId, expectedDigest;
}

/// Content-free fact, retained after removal. A package body is read separately.
class WorkspacePluginReceipt {
  const WorkspacePluginReceipt({
    required this.operationId,
    required this.action,
    required this.packageId,
    required this.expectedVersion,
    required this.version,
    this.digest,
  });
  final String operationId, packageId;
  final WorkspacePluginAction action;
  final int expectedVersion, version;
  final String? digest;
}

abstract interface class WorkspacePluginSource {
  Future<WorkspacePluginCatalog> load();
  Future<WorkspacePluginCandidate> prepareUpdate(
    WorkspacePluginUpdate update,
    int catalogVersion,
  );
  Future<WorkspacePluginPreview> previewInstall(String selectionId);

  /// Releases the chooser/form lease; committed receipts remain queryable.
  Future<void> releaseCandidate(String selectionId);
  Future<WorkspacePluginReceipt> change(WorkspacePluginChange change);

  /// null is confirmed absence; failed lookups throw and must never allow replay.
  Future<WorkspacePluginReceipt?> receipt(String operationId);
}
