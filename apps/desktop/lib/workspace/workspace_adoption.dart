import 'workspace_records.dart';
import 'workspace_plugins.dart';

class WorkspaceFieldMapping {
  const WorkspaceFieldMapping({
    this.sourceKey,
    this.sameMeaning = false,
    this.value = '',
  });
  final String? sourceKey;
  final bool sameMeaning;
  final String value;
}

class WorkspaceAdoptionDraft {
  WorkspaceAdoptionDraft({
    required this.ref,
    required this.typeId,
    Map<String, WorkspaceFieldMapping> fields = const {},
  }) : fields = Map.unmodifiable(fields);
  final WorkspaceRecordRef ref;
  final String typeId;
  final Map<String, WorkspaceFieldMapping> fields;
}

class WorkspaceAdoptionRow {
  const WorkspaceAdoptionRow({
    required this.key,
    required this.label,
    required this.sourceKey,
    required this.sourceLabel,
    required this.result,
    this.problem,
  });
  final String key, label, result;
  final String? sourceKey, sourceLabel, problem;
}

class WorkspaceAdoptionPreview {
  WorkspaceAdoptionPreview({
    required this.planId,
    required this.current,
    required this.target,
    required this.pluginVersion,
    required this.result,
    required Iterable<WorkspaceAdoptionRow> rows,
    required Iterable<String> retained,
    Map<String, String> errors = const {},
  }) : rows = List.unmodifiable(rows),
       retained = List.unmodifiable(retained),
       errors = Map.unmodifiable(errors);
  final String planId;
  final WorkspaceDetail current, result;
  final WorkspacePluginTemplate target;
  final int pluginVersion;
  final List<WorkspaceAdoptionRow> rows;
  final List<String> retained;
  final Map<String, String> errors;
  bool get canApply => errors.isEmpty;
}
