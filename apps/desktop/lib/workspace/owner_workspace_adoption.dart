import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_source.dart';
import 'workspace_entries.dart';
import 'workspace_information_codec.dart';
import 'owner_workspace_information.dart';

/// Owner-approved identity mapping. Preview never writes or grants access.
class OwnerWorkspaceAdoption {
  OwnerWorkspaceAdoption(this.information, this.plugins);
  final OwnerWorkspaceInformation information;
  final WorkspacePluginSource plugins;
  final _plans = <String, WorkspaceAdoptionPreview>{};
  void dispose() => _plans.clear();
  String _shape(Map field) =>
      const {
        'text',
        'url',
        'number',
        'date',
        'multiline',
      }.contains(field['type'])
      ? 'text'
      : field['type'] as String? ?? 'unknown';

  Future<WorkspaceAdoptionPreview> preview(WorkspaceAdoptionDraft draft) async {
    final current = await information.readDetail(draft.ref);
    final target = (await plugins.load()).packages
        .where((p) => p.enabled)
        .expand((p) => p.templates)
        .where((t) => t.type.id == draft.typeId)
        .firstOrNull;
    final original = information.owner.information.singleWhere(
      (i) => i.id == draft.ref.id,
    );
    if (original.layout != null &&
        original.layout!.snapshot['codec'] != 'workspace-information-v1') {
      throw const WorkspaceFailure('unsupported', '此资料布局无法安全采用模板。');
    }
    if (target == null) {
      throw const WorkspaceFailure('template_unavailable', '目标模板已停用或移除，请重新选择。');
    }
    if (_plans.length >= 100) {
      throw const WorkspaceFailure('preview_busy', '待核对的模板预览过多，请先关闭已有预览。');
    }
    final id = workspaceOperationId(),
        oldFields = {
          for (final f in workspaceFields(current)) f['key'] as String: f,
        };
    for (final key in current.values.keys) {
      oldFields.putIfAbsent(
        key,
        () => {
          'key': key,
          'label': key,
          'type': current.values[key] is String ? 'multiline' : 'unknown',
        },
      );
    }
    final values = <String, Object?>{},
        ids = <String, String>{},
        used = <String>{};
    final errors = <String, String>{}, rows = <WorkspaceAdoptionRow>[];
    final targetFields = [
      for (final f in target.definition['fields'] as List? ?? [])
        Map<String, Object?>.from(f as Map),
    ];
    if (draft.fields.keys.any((k) => !targetFields.any((f) => f['key'] == k))) {
      throw const WorkspaceFailure('validation', '字段对应包含目标模板以外的字段。');
    }
    for (final f in targetFields) {
      final key = f['key'] as String,
          mapping = draft.fields[key] ?? const WorkspaceFieldMapping();
      final source = oldFields[mapping.sourceKey];
      String? problem;
      var result = '新字段';
      Object? value = f['type'] == 'entries' ? const [] : mapping.value;
      if (mapping.sourceKey != null) {
        if (source == null) {
          problem = '来源字段已不可用。';
        } else if (_shape(source) != _shape(f) || _shape(source) == 'unknown') {
          problem = '内容形态不兼容，原字段将保留，请改选来源或新字段。';
        } else {
          value = current.values[mapping.sourceKey];
          if (mapping.sameMeaning) {
            if (!used.add(mapping.sourceKey!)) {
              problem = '同一来源只能保留到一个目标字段。';
            } else {
              result = '保留原身份';
              if (current.fieldIds[mapping.sourceKey] case final fieldId?) {
                ids[key] = fieldId;
              }
            }
          } else {
            result = '新身份；原字段另行保留';
          }
          if (f['type'] == 'entries' && !mapping.sameMeaning) {
            try {
              value = [
                for (final e in WorkspaceRepeatedEntry.read(value))
                  {
                    ...e.toJson(),
                    'entryId': workspaceOperationId(),
                    'fieldIds': {
                      for (final part in e.activeParts)
                        part: WorkspaceRepeatedEntry.empty().fieldIds[part],
                    },
                  },
              ];
            } on FormatException {
              problem = '经历结构无法采用，请保留原内容并核对来源。';
            }
          }
        }
      }
      values[key] = value;
      if (problem != null) errors[key] = problem;
      rows.add(
        WorkspaceAdoptionRow(
          key: key,
          label: f['label'] as String,
          sourceKey: mapping.sourceKey,
          sourceLabel: source?['label'] as String?,
          result: result,
          problem: problem,
        ),
      );
    }
    final retained = <Map<String, Object?>>[], labels = <String>[];
    for (final e in oldFields.entries.where((e) => !used.contains(e.key))) {
      // A separate instance namespace avoids overwriting a same-named target.
      final key = e.key.startsWith('retained:')
          ? e.key
          : 'retained:${current.fieldIds[e.key] ?? sha256.convert(utf8.encode('${draft.ref.key}/${e.key}')).toString()}';
      var type = e.value['type'];
      if (type == 'entries') {
        try {
          WorkspaceRepeatedEntry.read(current.values[e.key]);
        } on FormatException {
          type = 'unknown';
        }
      }
      retained.add({
        ...e.value,
        'type': type,
        'key': key,
        'originKey': e.value['originKey'] ?? e.key,
      });
      labels.add(e.value['label'] as String);
      values[key] = current.values[e.key];
      if (current.fieldIds[e.key] case final fieldId?) ids[key] = fieldId;
    }
    final priorRules = workspaceEditingDefinition(current)['relations'] as List;
    final keptRules = <Map<String, Object?>>[
      for (final r in priorRules)
        if ((current.relations[r['key']]?.isNotEmpty ?? false))
          Map<String, Object?>.from(r as Map),
      for (final key in current.relations.keys)
        if (key != 'credentials' &&
            current.relations[key]!.isNotEmpty &&
            !priorRules.any((r) => r['key'] == key))
          {'key': key, 'label': key, 'targetTemplates': <String>[]},
    ];
    final candidate = WorkspaceDetail(
      record: current.record.copyWith(
        type: target.type,
        updatedAt: current.record.updatedAt,
      ),
      version: current.version + 1,
      definition: target.definition,
      values: values,
      fieldIds: ids,
      retainedFields: retained,
      retainedRelations: keptRules,
      relations: current.relations,
    );
    try {
      WorkspaceInformationCodec().adopt(
        candidate,
        information.owner.information.singleWhere((i) => i.id == draft.ref.id),
        core.InformationRecordCommand(
          typeId: target.type.id,
          digest: '0' * 64,
          adoptionPlanId: id,
          templateCatalogVersion: information.owner.templatePackageVersion,
        ),
      );
    } on WorkspaceFailure catch (e) {
      errors.addAll(
        e.fieldErrors.isEmpty ? {'record': e.message} : e.fieldErrors,
      );
    }
    var leaves = workspaceFields(
      candidate,
    ).where((f) => f['type'] != 'entries').length;
    for (final f in workspaceFields(
      candidate,
    ).where((f) => f['type'] == 'entries')) {
      try {
        leaves +=
            WorkspaceRepeatedEntry.read(candidate.values[f['key']]).length * 3;
      } on FormatException {
        errors[f['key'] as String] = '经历结构需要核对，不能作为新布局提交。';
      }
    }
    if (leaves > 200) errors['budget'] = '保留字段与目标字段合计不能超过200个叶字段。';
    final preview = WorkspaceAdoptionPreview(
      planId: id,
      current: current,
      target: target,
      pluginVersion: information.owner.templatePackageVersion,
      result: candidate,
      rows: rows,
      retained: labels,
      errors: errors,
    );
    _plans[id] = preview;
    return preview;
  }

  Future<void> release(String id) async {
    _plans.remove(id);
  }

  Future<WorkspaceRecordReceipt> apply(
    String operationId,
    String planId,
  ) async {
    final prior = await information.recordOperationReceipt(operationId);
    if (prior != null) {
      if (prior.intent.kind != WorkspaceOperationKind.adoptTemplate ||
          prior.intent.planId != planId) {
        throw const WorkspaceFailure('conflict', '原操作编号不能用于另一份采用预览。');
      }
      return prior.result;
    }
    final plan = _plans[planId];
    if (plan == null) {
      throw const WorkspaceFailure('preview_expired', '预览已关闭，请重新预览。');
    }
    if (!plan.canApply) {
      throw WorkspaceFailure(
        'validation',
        '请先解决字段对应的问题。',
        fieldErrors: plan.errors,
      );
    }
    final result = await information.applyAdoption(
      operationId,
      plan,
      validate: () {
        if (!identical(_plans[planId], plan)) {
          throw const WorkspaceFailure('preview_expired', '预览已关闭，未应用模板。');
        }
      },
    );
    _plans.remove(planId);
    return result;
  }
}
