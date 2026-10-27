part of 'sample_workspace_source.dart';

extension _SampleAdoption on SampleWorkspaceSource {
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

  Future<WorkspaceAdoptionPreview> _previewAdoption(
    WorkspaceAdoptionDraft draft,
  ) async {
    await _readable();
    _ordinary(draft.ref);
    final current = _current(draft.ref),
        target = _plugins.template(draft.typeId);
    if (target == null) {
      throw const WorkspaceFailure('template_unavailable', '目标模板已停用或移除，请重新选择。');
    }
    if (_adoptionPlans.length >= 100) {
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
                    'entryId': 'adopt-entry-${_fingerprint([id, key, e.id])}',
                    'fieldIds': {
                      for (final part in e.activeParts)
                        part: sampleFieldId(
                          draft.ref,
                          '$id/$key/${e.id}/$part',
                        ),
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
      if (f['type'] != 'entries') {
        ids.putIfAbsent(key, () => sampleFieldId(draft.ref, '$id/$key'));
      }
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
          : 'retained:${current.fieldIds[e.key] ?? _fingerprint([draft.ref.key, e.key])}';
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
    final candidate = sampleWithFieldIds(
      WorkspaceDetail(
        record: current.record.copyWith(type: target.type, updatedAt: _now()),
        version: current.version + 1,
        definition: target.definition,
        values: values,
        fieldIds: ids,
        retainedFields: retained,
        retainedRelations: keptRules,
        relations: current.relations,
      ),
    );
    // Validation sees the approved identity move as the active locations. It
    // never grants those identities to another record or a different meaning.
    final context = WorkspaceDetail(
      record: current.record,
      version: current.version,
      definition: candidate.definition,
      values: candidate.values,
      fieldOverrides: candidate.fieldOverrides,
      retainedFields: candidate.retainedFields,
      fieldIds: candidate.fieldIds,
    );
    final validation = _fieldErrors(
      candidate.record.name,
      candidate.record.description,
      workspaceEditingDefinition(candidate),
      candidate.values,
      current: context,
    );
    for (final e in validation.entries) {
      errors.putIfAbsent(e.key, () => e.value);
    }
    var leaves = candidate.fieldIds.length;
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
      pluginVersion: _plugins.version,
      result: candidate,
      rows: rows,
      retained: labels,
      errors: errors,
    );
    _adoptionPlans[id] = preview;
    return preview;
  }

  Future<WorkspaceRecordReceipt> _applyAdoption(
    String operationId,
    String planId,
  ) async {
    await _readable();
    final fingerprint = _fingerprint(['adopt-template', planId]);
    if (operationId.trim().isEmpty || _operations.containsKey(operationId)) {
      throw const WorkspaceFailure('operation_conflict', '采用操作身份无效或已被使用。');
    }
    if (_recordOperations[operationId] case final prior?) {
      if (prior.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同预览。');
      }
      return prior.receipt;
    }
    final plan = _adoptionPlans[planId];
    if (plan == null) {
      throw const WorkspaceFailure('preview_expired', '采用预览已释放，请重新预览。');
    }
    final current = _current(plan.current.record.ref),
        target = _plugins.template(plan.target.type.id);
    if (current.version != plan.current.version ||
        _plugins.version != plan.pluginVersion ||
        target == null ||
        _fingerprint(target.definition) !=
            _fingerprint(plan.target.definition)) {
      throw const WorkspaceFailure('conflict', '资料或目标模板已变化，请重新预览字段对应。');
    }
    if (!plan.canApply) {
      throw WorkspaceFailure(
        'validation',
        '请先解决字段对应中的问题。',
        fieldErrors: plan.errors,
      );
    }
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
    for (final old in workspaceFields(
      current,
    ).where((f) => f['type'] == 'file')) {
      final original = old['key'] as String;
      for (final f in workspaceFields(
        plan.result,
      ).where((f) => f['type'] == 'file')) {
        final key = f['key'] as String;
        if (plan.result.fieldIds[key] == current.fieldIds[original]) {
          _files.aliasField(current.record.ref, key, original);
        }
      }
    }
    (_revisions[current.record.ref] ??= []).add(_archive(current));
    _putRecord(plan.result);
    _entryIdentityOwners.addAll(sampleEntryOwners(plan.result));
    final receipt = WorkspaceRecordReceipt(
      ref: current.record.ref,
      version: plan.result.version,
    );
    _recordOperations[operationId] = (
      fingerprint: fingerprint,
      receipt: receipt,
    );
    _adoptionPlans.remove(planId);
    _changes.add(current.record.ref);
    _recordCommitted(
      operationId,
      WorkspaceOperationIntent(
        kind: WorkspaceOperationKind.adoptTemplate,
        ref: current.record.ref,
        typeId: plan.target.type.id,
        expectedVersion: current.version,
        planId: planId,
      ),
      receipt,
    );
    return receipt;
  }
}
