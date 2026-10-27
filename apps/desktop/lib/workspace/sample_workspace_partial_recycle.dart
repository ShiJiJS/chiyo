part of 'sample_workspace_source.dart';

extension _SamplePartialRecycle on SampleWorkspaceSource {
  WorkspaceDetail _restorePartial(
    WorkspaceArchive archive,
    WorkspaceDetail current,
    int version,
    String operationId,
    List<String> notices,
  ) {
    final old = archive.detail, ref = current.record.ref;
    final values = Map<String, Object?>.of(current.values),
        ids = Map<String, String>.of(current.fieldIds),
        overrides = Map<String, Map<String, Object?>?>.of(
          current.fieldOverrides,
        ),
        retained = List<Map<String, Object?>>.of(current.retainedFields);
    final oldFields = {
      for (final f in workspaceFields(old)) f['key'] as String: f,
    };
    String fresh(String key) =>
        sampleFieldId(ref, 'partial-restore/$operationId/$key');
    for (final e in old.values.entries) {
      final key = e.key, field = oldFields[key];
      if (field == null) {
        throw const WorkspaceFailure('unsupported', '回收字段缺少原定义，不能按同名字段重建。');
      }
      if (field['type'] == 'entries') {
        final rows = WorkspaceRepeatedEntry.read(
          values[key],
        ).map((x) => x.toJson()).toList();
        for (final fragment in WorkspaceRepeatedEntry.read(e.value)) {
          final index = rows.indexWhere((x) => x['entryId'] == fragment.id);
          final active = index < 0
              ? null
              : WorkspaceRepeatedEntry.fromJson(rows[index]);
          final collision =
              active != null &&
              fragment.activeParts.any(active.fieldIds.containsKey);
          if (active != null && !collision) {
            final row = {...active.toJson()}, leafIds = {...active.fieldIds};
            final definitions = Map<String, Object?>.from(
                  row['definitions'] as Map? ?? {},
                ),
                savedDefinitions =
                    fragment.toJson()['definitions'] as Map? ?? {};
            for (final part in fragment.activeParts) {
              leafIds[part] = fresh('$key/${fragment.id}/$part');
              row[part] = fragment.toJson()[part];
              if (savedDefinitions[part] != null) {
                definitions[part] = savedDefinitions[part];
              }
            }
            rows[index] = {
              ...row,
              'fieldIds': leafIds,
              'definitions': definitions,
            };
          } else {
            rows.add({
              ...fragment.toJson(),
              'entryId':
                  'restored-entry-${_fingerprint([operationId, key, fragment.id])}',
              'fieldIds': {
                for (final part in fragment.activeParts)
                  part: fresh('$key/${fragment.id}/$part'),
              },
            });
            if (collision) notices.add('原经历已有同位置字段，旧内容恢复为独立经历，没有覆盖当前内容。');
          }
        }
        values[key] = rows;
      } else {
        var targetKey = key;
        if (values.containsKey(key) || ids.containsKey(key)) {
          targetKey = 'retained:restore:${_fingerprint([operationId, key])}';
          retained.add({...field, 'key': targetKey, 'originKey': key});
          notices.add('“${field['label']}”已有当前字段，旧内容恢复为独立保留字段。');
        } else {
          overrides[key] = field;
        }
        values[targetKey] = e.value;
        ids[targetKey] = fresh(targetKey);
      }
    }
    // Explicit restoration receives new identities. Generic editing cannot
    // do this; validate against the result only after the merge above is fixed.
    final restored = WorkspaceDetail(
      record: current.record.copyWith(updatedAt: _now()),
      version: version,
      definition: current.definition,
      fieldOverrides: overrides,
      fieldIds: ids,
      retainedFields: retained,
      retainedRelations: current.retainedRelations,
      values: values,
      relations: current.relations,
    );
    final leaves = workspaceFields(restored).fold<int>(
      0,
      (sum, f) =>
          sum +
          (f['type'] == 'entries'
              ? WorkspaceRepeatedEntry.read(
                  restored.values[f['key']],
                ).fold<int>(0, (n, e) => n + e.fieldIds.length)
              : 1),
    );
    if (leaves > 200) {
      throw const WorkspaceFailure('validation', '恢复后超过每项资料200字段预算，请先整理当前内容。');
    }
    return restored;
  }
}
