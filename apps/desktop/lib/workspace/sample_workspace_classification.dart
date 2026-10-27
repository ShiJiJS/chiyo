part of 'sample_workspace_source.dart';

extension _SampleClassification on SampleWorkspaceSource {
  WorkspaceRecordSummary _currentClassification(WorkspaceRecordSummary r) {
    final tags = {for (final t in _catalog.tags) t.id: t};
    return r.copyWith(tags: [for (final t in r.tags) ?tags[t.id]]);
  }

  Map<WorkspaceRecordRef, int> _tagMembers(String id) => {
    if (_scenario != SampleWorkspaceScenario.empty)
      for (final d in _records.values)
        if (d.record.tags.any((t) => t.id == id)) d.record.ref: d.version,
  };
  bool _sameMembers(
    Map<WorkspaceRecordRef, int> a,
    Map<WorkspaceRecordRef, int> b,
  ) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  Future<WorkspaceTagRemovalPreview> _previewTagRemoval(String id) async {
    final epoch = _epoch;
    await _readable();
    if (epoch != _epoch) {
      throw const WorkspaceFailure('cancelled', '资料来源已变化，请重新核对标签。');
    }
    if (!_catalog.tags.any((t) => t.id == id)) {
      throw const WorkspaceFailure('not_found', '标签已不存在，请重新读取。');
    }
    final versions = _tagMembers(id);
    final p = WorkspaceTagRemovalPreview(
      token: workspaceOperationId(),
      tagId: id,
      catalogVersion: _catalogVersion,
      affectedCount: versions.length,
    );
    _tagRemovalPlans.removeWhere(
      (_, p) =>
          p.epoch != _epoch || p.preview.catalogVersion != _catalogVersion,
    );
    if (_tagRemovalPlans.length >= 32) {
      _tagRemovalPlans.remove(_tagRemovalPlans.keys.first);
    }
    _tagRemovalPlans[p.token] = (epoch: _epoch, preview: p, versions: versions);
    return p;
  }

  WorkspaceClassificationReceipt _finishClassification(
    WorkspaceClassificationChange c, {
    required String targetId,
    WorkspaceDirectory? directory,
    WorkspaceTag? tag,
  }) {
    final receipt = WorkspaceClassificationReceipt(
      operationId: c.operationId,
      commandDigest: c.digest,
      expectedVersion: c.expectedVersion,
      version: _catalogVersion,
      targetId: targetId,
      directory: directory,
      tag: tag,
    );
    _classificationReceipts[c.operationId] = receipt;
    _tagRemovalPlans.clear();
    _changes.add(null);
    if (loseNextClassificationReply) {
      loseNextClassificationReply = false;
      throw const WorkspaceFailure(
        'unknown_outcome',
        '分类操作结果未知，请核对原操作，不要重复提交。',
      );
    }
    return receipt;
  }

  Future<WorkspaceClassificationReceipt> _changeClassification(
    WorkspaceClassificationChange c,
  ) async {
    final epoch = _epoch;
    await _readable();
    if (epoch != _epoch) {
      throw const WorkspaceFailure('cancelled', '资料来源已变化，请重新核对分类。');
    }
    if (c.operationId.trim().isEmpty || c.operationId.length > 200) {
      throw const WorkspaceFailure('validation', '分类操作身份无效。');
    }
    if (_classificationReceipts[c.operationId] case final previous?) {
      if (!previous.matches(c)) {
        throw const WorkspaceFailure('operation_conflict', '同次操作不能用于不同分类内容。');
      }
      return previous;
    }
    if (c is WorkspaceDirectoryChange) {
      await changeDirectory(c);
      return _classificationReceipts[c.operationId]!;
    }
    if (c is! WorkspaceTagChange) {
      throw const WorkspaceFailure('unsupported', '分类操作不可用。');
    }
    if (c.expectedVersion != _catalogVersion) {
      throw const WorkspaceFailure('conflict', '目录或标签已变化，请重新读取后核对。');
    }
    final current = _catalog.tags.where((t) => t.id == c.tagId).firstOrNull;
    if (c.creating ? c.tagId != null : current == null) {
      throw const WorkspaceFailure('not_found', '标签已不存在或目标无效。');
    }
    final members = <WorkspaceDetail>[];
    WorkspaceTag? result;
    if (c.deleting) {
      final plan = _tagRemovalPlans[c.removalToken];
      if (plan == null ||
          plan.epoch != _epoch ||
          plan.preview.tagId != c.tagId ||
          plan.preview.catalogVersion != _catalogVersion ||
          !_sameMembers(plan.versions, _tagMembers(c.tagId!))) {
        throw const WorkspaceFailure('conflict', '标签影响范围已变化，请重新读取数量再确认，尚未删除。');
      }
      for (final ref in plan.versions.keys) {
        members.add(_projectRecord(_records[ref]!));
      }
    } else {
      final name = c.name.trim();
      if (name.isEmpty ||
          c.name.length > 200 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
        throw const WorkspaceFailure(
          'validation',
          '请核对标签名称。',
          fieldErrors: {'name': '请输入1–200字的标签名称，不包含控制字符。'},
        );
      }
      if (_catalog.tags.any(
        (t) => t.id != c.tagId && t.name.toLowerCase() == name.toLowerCase(),
      )) {
        throw const WorkspaceFailure(
          'validation',
          '标签名称已存在。',
          fieldErrors: {'name': '已有同名标签，请使用其他名称。'},
        );
      }
      result = WorkspaceTag(
        c.creating ? 'preview-tag-${workspaceOperationId()}' : current!.id,
        name,
      );
    }
    _beforeApprovalWrite();
    // All reviewed member versions, snapshots, current relations and catalog
    // commit together without await. A real adapter needs a durable transaction.
    for (final old in members) {
      (_revisions[old.record.ref] ??= []).add(_archive(old));
      final next = WorkspaceDetail(
        record: old.record.copyWith(
          tags: old.record.tags.where((t) => t.id != c.tagId),
          updatedAt: _now(),
        ),
        version: old.version + 1,
        definition: old.definition,
        values: old.values,
        fieldIds: old.fieldIds,
        fieldOverrides: old.fieldOverrides,
        retainedFields: old.retainedFields,
        retainedRelations: old.retainedRelations,
        relations: old.relations,
      );
      _putRecord(next);
    }
    final tags = _catalog.tags.where((t) => t.id != c.tagId).toList();
    if (result != null) tags.add(result);
    _catalog = WorkspaceCatalog(
      directories: _catalog.directories,
      tags: tags,
      types: _catalog.types,
    );
    _catalogVersion++;
    if (_scenario == SampleWorkspaceScenario.empty) _materializeEmpty();
    return _finishClassification(
      c,
      targetId: result?.id ?? current!.id,
      tag: result,
    );
  }
}
