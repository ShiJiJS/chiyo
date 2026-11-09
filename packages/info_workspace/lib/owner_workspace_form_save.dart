import 'package:info_core/info_core.dart' as core;
import 'owner_file_stages.dart';
import 'workspace_information_codec.dart';
import 'workspace_records.dart';

/// The existing owner form transaction, shared by desktop and online hosts.
/// Selection handles are resolved here; callers cannot supply encrypted stage IDs.
class OwnerWorkspaceFormSave {
  OwnerWorkspaceFormSave(this.owner, this.selections);
  final core.OwnerAccess owner;
  final OwnerFileSelectionSource? selections;
  final _codec = WorkspaceInformationCodec();

  Future<core.InformationRecordReceipt> create(
    WorkspaceCreate draft,
    Map<String, Object?> definition,
  ) async {
    final selected = {
      for (final e in draft.fileSelections.entries)
        e.key:
            selections?.selection(e.value) ??
            (throw const WorkspaceFailure('selection_expired', '附件选择已失效。')),
    };
    if (selected.values.map((s) => s.draft.id).toSet().length > 1 ||
        selected.values.map((s) => s.stage.id).toSet().length !=
            selected.length) {
      throw const WorkspaceFailure('selection_expired', '请为各字段分别选择同一表单中的附件。');
    }
    final input = _codec.create(
      draft,
      definition,
      stagedFiles: {for (final e in selected.entries) e.key: e.value.stage.id},
    );
    checkWorkspaceInformationRelations(owner, input, null);
    final receipt = selected.isEmpty
        ? await owner.saveInformationRecord(draft.operationId, input)
        : await owner.saveInformationFormRecord(
            selected.values.first.draft,
            draft.operationId,
            input,
          );
    for (final selected in selected.values) {
      await selections!.committed(selected.resource.selectionId);
    }
    return receipt;
  }
}

void checkWorkspaceInformationRelations(
  core.OwnerAccess owner,
  core.InformationDraftInput input,
  core.InformationItem? before,
) {
  final layout = input.layout!.layout;
  final definition = layout.snapshot['definition'] as Map;
  final rules = <String, Map>{
    for (final raw in definition['relations'] as List? ?? [])
      (raw as Map)['key'] as String: raw,
    for (final raw in layout.snapshot['retainedRelations'] as List? ?? [])
      (raw as Map)['key'] as String: raw,
  };
  for (final group in layout.relations.entries) {
    final rule = rules[group.key];
    for (final target in group.value) {
      // Existing dangling links are part of the saved record and survive
      // unrelated edits. New links must resolve to an eligible live target.
      if (before?.layout?.relations[group.key]?.contains(target) == true) {
        continue;
      }
      String? type;
      if (target.kind == 'information') {
        final item = owner.information
            .where((i) => i.id == target.id)
            .firstOrNull;
        if (item != null && item.id != before?.id) {
          type = item.layout?.typeId ?? 'generic';
        }
      } else if (owner.credentials.any((c) => c.id == target.id)) {
        type = 'credential';
      }
      final allowed = rule?['targetTemplates'] as List? ?? [];
      if (rule == null ||
          type == null ||
          (group.key == 'credentials' && target.kind != 'credential') ||
          (allowed.isNotEmpty &&
              !allowed.any((t) => workspaceTypeMatches(type!, t as String)))) {
        throw WorkspaceFailure(
          'validation',
          '关联目标已不可用或不符合资料类型。',
          fieldErrors: {'relation:${group.key}': '请重新选择关联资料。'},
        );
      }
    }
  }
}
