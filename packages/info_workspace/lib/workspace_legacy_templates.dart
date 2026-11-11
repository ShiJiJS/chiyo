import 'workspace_records.dart';

/// These remain form aids with definition identities, not record types/grants.
enum WorkspaceLegacyFieldKind { structured, textNote, file }

class WorkspaceLegacyField {
  const WorkspaceLegacyField(this.id, this.name, this.description, this.kind);
  final String id, name, description;
  final WorkspaceLegacyFieldKind kind;
}

class WorkspaceLegacyTemplate {
  WorkspaceLegacyTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required Iterable<WorkspaceLegacyField> fields,
    required Map<String, Object?> definition,
  }) : fields = List.unmodifiable(fields),
       definition = workspaceImmutableMap(definition);
  final String id, name, description;
  final int version;
  final List<WorkspaceLegacyField> fields;

  /// Host form projection retains the original definition-ID map separately.
  final Map<String, Object?> definition;
}

abstract interface class WorkspaceLegacyTemplateSource {
  Future<List<WorkspaceLegacyTemplate>> load();
  Future<WorkspaceLegacyTemplate> read(String id);
}
