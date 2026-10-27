part of 'sample_workspace_source.dart';

class _ProposalFieldPlan {
  const _ProposalFieldPlan(this.current, this.result, this.removed);
  final WorkspaceDetail current, result;
  final WorkspaceDetail? removed;
}

extension _SampleProposalFields on _SampleProposals {
  void demonstrateFieldChanges() {
    _seed();
    void add(
      String id,
      String title,
      WorkspaceDetail target,
      List<WorkspaceProposalFieldChange> changes, {
      bool deletion = false,
    }) {
      if (_rows.containsKey(id)) return;
      final metadata = WorkspaceDetail(
        record: target.record,
        version: target.version,
        definition: target.definition,
        fieldIds: target.fieldIds,
        fieldOverrides: target.fieldOverrides,
        retainedFields: target.retainedFields,
        retainedRelations: target.retainedRelations,
      );
      _rows[id] = _ProposalInput(
        id,
        title,
        deletion
            ? WorkspaceProposalKind.deletion
            : WorkspaceProposalKind.modification,
        deletion ? '仅删除列出的单个普通字段，不删除整条资料。' : '逐字段核对含义和身份；未列出的资料保持当前内容。',
        s._now(),
        [
          WorkspaceProposalItem(
            id: id,
            before: metadata,
            proposed: WorkspaceDetail(
              record: metadata.record,
              version: metadata.version,
              definition: metadata.definition,
              fieldIds: metadata.fieldIds,
              fieldOverrides: metadata.fieldOverrides,
              retainedFields: metadata.retainedFields,
              retainedRelations: metadata.retainedRelations,
              values: {
                for (final c in changes)
                  if (c.intent != WorkspaceProposalFieldIntent.remove)
                    c.reviewKey: c.after,
              },
            ),
            changes: changes,
          ),
        ],
      );
    }

    final server = s._records[info('aliyun')],
        profile = s._records[info('profile')],
        service = s._records[info('blinko')];
    if (server != null) {
      add('fields-server', '调整服务器字段与含义', server, [
        WorkspaceProposalFieldChange(
          intent: WorkspaceProposalFieldIntent.correct,
          key: 'port',
          label: 'SSH 端口 · 修正',
          fieldId: server.fieldIds['port'],
          after: '2222',
        ),
        WorkspaceProposalFieldChange(
          intent: WorkspaceProposalFieldIntent.add,
          key: 'recoveryContact',
          label: '恢复联系人 · 新增',
          after: 'recovery@beichen.example',
          definition: {
            'label': '恢复联系人',
            'type': 'text',
            'description': '恢复服务时的联系地址',
          },
        ),
        WorkspaceProposalFieldChange(
          intent: WorkspaceProposalFieldIntent.replace,
          key: 'user',
          label: '用户名 → 运维联系标识 · 替换含义',
          fieldId: server.fieldIds['user'],
          after: 'ops@beichen.example',
          definition: {
            'label': '运维联系标识',
            'type': 'text',
            'description': '用于联系维护人员，不是登录用户名',
          },
        ),
        WorkspaceProposalFieldChange(
          intent: WorkspaceProposalFieldIntent.remove,
          key: 'purpose',
          label: '旧日常用途 · 删除字段',
          fieldId: server.fieldIds['purpose'],
        ),
      ]);
    }
    if (profile != null) {
      final entry = WorkspaceRepeatedEntry.read(
        profile.values['education'],
      ).firstOrNull;
      if (entry != null) {
        add('fields-profile', '逐叶更新教育经历', profile, [
          WorkspaceProposalFieldChange(
            intent: WorkspaceProposalFieldIntent.correct,
            key: 'education',
            entryId: entry.id,
            leaf: 'title',
            fieldId: entry.fieldIds['title'],
            label: '第一段教育 · 名称修正',
            after: '北辰大学 · 计算机硕士（已核对）',
          ),
          WorkspaceProposalFieldChange(
            intent: WorkspaceProposalFieldIntent.replace,
            key: 'education',
            entryId: entry.id,
            leaf: 'detail',
            fieldId: entry.fieldIds['detail'],
            label: '第一段教育 · 说明 → 研究成果',
            after: '完成服务交互研究',
            definition: {
              'label': '研究成果',
              'type': 'multiline',
              'description': '单独记录研究成果，使用新的字段身份',
            },
          ),
          WorkspaceProposalFieldChange(
            intent: WorkspaceProposalFieldIntent.remove,
            key: 'education',
            entryId: entry.id,
            leaf: 'period',
            fieldId: entry.fieldIds['period'],
            label: '第一段教育 · 删除时间',
          ),
          for (final part in WorkspaceRepeatedEntry.parts)
            WorkspaceProposalFieldChange(
              intent: WorkspaceProposalFieldIntent.add,
              key: 'education',
              entryId: 'proposal-entry:new-education',
              leaf: part,
              label: '新增教育经历 · ${WorkspaceRepeatedEntry.labels[part]}',
              after: {
                'title': '北辰学院 · 继续教育',
                'period': '2026',
                'detail': '系统设计课程',
              }[part],
              definition: {
                'label': WorkspaceRepeatedEntry.labels[part],
                'type': part == 'detail' ? 'multiline' : 'text',
              },
            ),
        ]);
      }
    }
    if (service != null) {
      add('delete-field', '删除 Blinko 认证方式字段', service, [
        WorkspaceProposalFieldChange(
          intent: WorkspaceProposalFieldIntent.remove,
          key: 'auth',
          fieldId: service.fieldIds['auth'],
          label: '认证方式 · 删除字段',
        ),
      ], deletion: true);
    }
    s._changes.add(null);
  }

  _ProposalFieldPlan _fieldPlan(
    WorkspaceProposalItem item,
    WorkspaceProposalItemReview review,
    String operationId,
  ) {
    final original = item.before!, ref = original.record.ref;
    final current = s._current(ref);
    if (current.version != original.version) {
      throw const WorkspaceFailure('conflict', '资料版本已变化，请重新生成提案。');
    }
    final baseline = WorkspaceProposalItemReview.fromItem(item);
    final expectedKeys = item.changes
        .where((c) => c.intent != WorkspaceProposalFieldIntent.remove)
        .map((c) => c.reviewKey)
        .toSet();
    if (review.name != baseline.name ||
        review.description != baseline.description ||
        review.directoryId != baseline.directoryId ||
        !_same(review.tagIds, baseline.tagIds) ||
        !_same(
          _relationKeys(review.relations),
          _relationKeys(baseline.relations),
        ) ||
        review.values.keys.toSet().length != expectedKeys.length ||
        !review.values.keys.every(expectedKeys.contains) ||
        item.changes.isEmpty ||
        item.changes.length > 200 ||
        utf8.encode(jsonEncode(review.toJson())).length > 240000) {
      throw const WorkspaceFailure('validation', '只能提交本提案明确列出的字段变化。');
    }
    final values = Map<String, Object?>.of(current.values),
        ids = Map<String, String>.of(current.fieldIds),
        overrides = Map<String, Map<String, Object?>?>.of(
          current.fieldOverrides,
        );
    final fields = {
      for (final f in workspaceFields(current)) f['key'] as String: f,
    };
    final removedValues = <String, Object?>{},
        removedIds = <String, String>{},
        removedEntries = <String, Map<String, Map<String, Object?>>>{};
    final intentErrors = <String, String>{};
    final collections = <String, List<Map<String, Object?>>>{},
        temporary = <String, String>{},
        touched = <String>{},
        changedLeaves = <String>{};
    String fresh(String seed) =>
        sampleFieldId(ref, 'proposal/$operationId/$seed');
    Map<String, Object?> definition(WorkspaceProposalFieldChange c) {
      final d = c.definition;
      if (d == null ||
          d['label'] is! String ||
          (d['label'] as String).trim().isEmpty ||
          (d['label'] as String).length > 200 ||
          !['text', 'multiline', 'number', 'date'].contains(d['type']) ||
          (d['description'] != null && d['description'] is! String) ||
          (d['required'] != null && d['required'] is! bool) ||
          (d['description'] is String &&
              (d['description'] as String).length > 2000)) {
        throw const WorkspaceFailure('validation', '新增或替换字段需要明确的名称、含义和普通内容类型。');
      }
      return {
        'key': c.key,
        'label': d['label'],
        'type': d['type'],
        'description': d['description'] ?? '',
        'required': d['required'] == true,
      };
    }

    for (final c in item.changes) {
      if (!touched.add(c.reviewKey)) {
        throw const WorkspaceFailure('validation', '同一字段不能在一份提案中重复变化。');
      }
      final text = review.values[c.reviewKey];
      if (c.intent != WorkspaceProposalFieldIntent.remove &&
          (text is! String || text.length > 64000)) {
        throw WorkspaceFailure(
          'validation',
          '请检查字段值。',
          fieldErrors: {
            'item:${item.id}:value:${c.reviewKey}': '请输入不超过64000字的普通文本。',
          },
        );
      }
      if (c.entryId == null) {
        final old = fields[c.key];
        if (c.intent == WorkspaceProposalFieldIntent.add
            ? old != null || c.fieldId != null
            : old == null ||
                  current.fieldIds[c.key] != c.fieldId ||
                  c.fieldId == null) {
          throw const WorkspaceFailure('conflict', '字段身份或新增范围与原资料不符。');
        }
        if (old != null &&
            !['text', 'multiline', 'number', 'date'].contains(old['type'])) {
          throw const WorkspaceFailure(
            'unsupported',
            '经历按叶字段处理；普通附件和未知结构继续使用专用流程。',
          );
        }
        if (c.intent == WorkspaceProposalFieldIntent.add &&
            !RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,159}$').hasMatch(c.key)) {
          throw const WorkspaceFailure('validation', '新字段定义键无效。');
        }
        if (c.intent == WorkspaceProposalFieldIntent.remove ||
            c.intent == WorkspaceProposalFieldIntent.replace) {
          removedValues[c.key] = current.values[c.key];
          removedIds[c.key] = current.fieldIds[c.key]!;
        }
        switch (c.intent) {
          case WorkspaceProposalFieldIntent.correct:
            values[c.key] = text;
          case WorkspaceProposalFieldIntent.remove:
            values.remove(c.key);
            ids.remove(c.key);
            overrides[c.key] = null;
          case WorkspaceProposalFieldIntent.add:
          case WorkspaceProposalFieldIntent.replace:
            overrides[c.key] = definition(c);
            ids[c.key] = fresh(c.reviewKey);
            values[c.key] = text;
        }
        continue;
      }
      if (fields[c.key]?['type'] != 'entries' ||
          !WorkspaceRepeatedEntry.parts.contains(c.leaf)) {
        throw const WorkspaceFailure('unsupported', '经历变更必须明确到一段经历的单个叶字段。');
      }
      final rows = collections.putIfAbsent(c.key, () {
        try {
          return WorkspaceRepeatedEntry.read(
            current.values[c.key],
          ).map((e) => e.toJson()).toList();
        } on FormatException {
          throw const WorkspaceFailure('unsupported', '原经历结构无法编辑，请保留原文。');
        }
      });
      final originalEntry = WorkspaceRepeatedEntry.read(
        current.values[c.key],
      ).where((e) => e.id == c.entryId).firstOrNull;
      if (c.intent == WorkspaceProposalFieldIntent.add
          ? originalEntry?.fieldIds.containsKey(c.leaf) == true ||
                c.fieldId != null
          : originalEntry?.fieldIds[c.leaf] != c.fieldId || c.fieldId == null) {
        throw const WorkspaceFailure('conflict', '经历叶字段身份已变化，不能按名称对应。');
      }
      if (originalEntry == null &&
          (!c.entryId!.startsWith('proposal-entry:') ||
              c.intent != WorkspaceProposalFieldIntent.add)) {
        throw const WorkspaceFailure('conflict', '新增经历需使用本提案的临时身份。');
      }
      final entryId =
          originalEntry?.id ??
          temporary.putIfAbsent(
            '${c.key}/${c.entryId}',
            () =>
                'proposal-entry-${s._fingerprint([operationId, c.key, c.entryId])}',
          );
      var index = rows.indexWhere((e) => e['entryId'] == entryId);
      if (index < 0) {
        rows.add({
          'entryId': entryId,
          'fieldIds': <String, String>{},
          for (final p in WorkspaceRepeatedEntry.parts) p: '',
        });
        index = rows.length - 1;
      }
      final row = Map<String, Object?>.of(rows[index]),
          leafIds = Map<String, String>.from(row['fieldIds'] as Map),
          leaf = c.leaf!;
      final descriptors = Map<String, Object?>.from(
        row['definitions'] as Map? ?? {},
      );
      if (c.intent == WorkspaceProposalFieldIntent.replace ||
          c.intent == WorkspaceProposalFieldIntent.remove) {
        final fragments = removedEntries.putIfAbsent(c.key, () => {});
        final fragment = fragments.putIfAbsent(
          originalEntry!.id,
          () => {
            'entryId': originalEntry.id,
            'fieldIds': <String, String>{},
            'definitions': originalEntry.toJson()['definitions'] ?? {},
            for (final p in WorkspaceRepeatedEntry.parts) p: '',
          },
        );
        (fragment['fieldIds'] as Map<String, String>)[leaf] =
            originalEntry.fieldIds[leaf]!;
        fragment[leaf] = originalEntry.toJson()[leaf];
      }
      switch (c.intent) {
        case WorkspaceProposalFieldIntent.correct:
          row[leaf] = text;
        case WorkspaceProposalFieldIntent.remove:
          leafIds.remove(leaf);
          row[leaf] = '';
          descriptors.remove(leaf);
        case WorkspaceProposalFieldIntent.add:
        case WorkspaceProposalFieldIntent.replace:
          final d = definition(c);
          descriptors[leaf] = {...d, 'key': leaf};
          leafIds[leaf] = fresh(c.reviewKey);
          row[leaf] = text;
          changedLeaves.add('${c.key}:$entryId:$leaf');
      }
      row['fieldIds'] = leafIds;
      row['definitions'] = descriptors;
      rows[index] = row;
      if (c.intent != WorkspaceProposalFieldIntent.remove) {
        final descriptor = descriptors[leaf] as Map?;
        intentErrors.addAll(
          s._fieldErrors(
            current.record.name,
            current.record.description,
            {
              'fields': [
                {
                  'key': c.reviewKey,
                  'label': c.label,
                  'type': descriptor?['type'] ?? 'text',
                  'required': descriptor?['required'] == true,
                },
              ],
            },
            {c.reviewKey: text},
            current: current,
          ),
        );
      }
    }
    for (final e in collections.entries) {
      values[e.key] = e.value
          .where((row) => (row['fieldIds'] as Map).isNotEmpty)
          .toList();
    }
    for (final e in removedEntries.entries) {
      removedValues[e.key] = e.value.values.toList();
    }
    final result = WorkspaceDetail(
      record: current.record.copyWith(updatedAt: s._now()),
      version: current.version + 1,
      definition: current.definition,
      fieldIds: ids,
      fieldOverrides: overrides,
      retainedFields: current.retainedFields,
      retainedRelations: current.retainedRelations,
      values: values,
      relations: current.relations,
    );
    final errors = s._fieldErrors(
      result.record.name,
      result.record.description,
      workspaceEditingDefinition(result),
      result.values,
      current: current,
      changedLeaves: changedLeaves,
    );
    errors.addAll(intentErrors);
    for (final c in item.changes.where((c) => c.entryId != null)) {
      final actualId = temporary['${c.key}/${c.entryId}'] ?? c.entryId;
      final message = errors.remove('${c.key}:$actualId:${c.leaf}');
      if (message != null) errors['value:${c.reviewKey}'] = message;
    }

    var count = 0;
    for (final f in workspaceFields(result)) {
      if (f['type'] == 'entries') {
        count += WorkspaceRepeatedEntry.read(
          result.values[f['key']],
        ).fold<int>(0, (sum, e) => sum + e.fieldIds.length);
      } else {
        count++;
      }
    }
    if (count > 200) errors['fields'] = '每项资料最多200个字段，经历逐叶计数。';
    if (errors.isNotEmpty) {
      throw WorkspaceFailure(
        'validation',
        '请检查标记的字段。',
        fieldErrors: {
          for (final e in errors.entries) 'item:${item.id}:${e.key}': e.value,
        },
      );
    }
    return _ProposalFieldPlan(
      current,
      result,
      removedValues.isEmpty
          ? null
          : WorkspaceDetail(
              record: current.record,
              version: current.version,
              definition: current.definition,
              fieldIds: removedIds,
              fieldOverrides: current.fieldOverrides,
              retainedFields: current.retainedFields,
              retainedRelations: current.retainedRelations,
              values: removedValues,
            ),
    );
  }

  WorkspaceRecordReceipt _commitFieldPlan(_ProposalFieldPlan plan) {
    if (s.nextSaveFailure case final failure?) {
      s.nextSaveFailure = null;
      throw failure;
    }
    final ref = plan.current.record.ref;
    (s._revisions[ref] ??= []).add(s._archive(plan.current));
    String? entryId;
    if (plan.removed case final removed?) {
      entryId = 'preview-recycle-${++s._nextRecycle}';
      final now = s._now();
      s._recycled[entryId] = (
        entry: WorkspaceRecycleEntry(
          id: entryId,
          record: removed.record,
          version: plan.result.version,
          deletedAt: now,
          expiresAt: now.add(const Duration(days: 30)),
          wholeItem: false,
          directoryName: s._archive(removed).directoryName,
        ),
        archive: s._archive(removed, wholeItem: false),
      );
    }
    s._putRecord(plan.result);
    s._entryIdentityOwners.addAll(sampleEntryOwners(plan.result));
    s._changes.add(ref);
    return WorkspaceRecordReceipt(
      ref: ref,
      version: plan.result.version,
      entryId: entryId,
    );
  }
}
