part of 'sample_workspace_source.dart';

extension _SampleHistory on SampleWorkspaceSource {
  int _pageOffset(int offset, int limit, int total) =>
      total == 0 ? 0 : offset.clamp(0, (total - 1) ~/ limit * limit);

  WorkspaceArchive _archive(WorkspaceDetail detail) => WorkspaceArchive(
    detail: detail,
    archivedAt: _now(),
    directoryName: _catalog.directories
        .where((d) => d.id == detail.record.directoryId)
        .firstOrNull
        ?.name,
    targets: {
      for (final ref in detail.relations.values.expand((r) => r))
        if (_records[ref] case final target?) ref: target.record,
    },
  );

  void _forgetContent(WorkspaceRecordRef ref) {
    _revisions.remove(ref);
    for (final id in _operations.keys.toList()) {
      final op = _operations[id]!;
      if (op.result case WorkspaceSaved(
        :final detail,
      ) when detail.record.ref == ref) {
        _operations[id] = (
          fingerprint: op.fingerprint,
          result: const WorkspaceRejected(
            WorkspaceFailure('purged', '资料已永久清理，不能重放旧的保存结果。'),
          ),
        );
      }
    }
  }

  void _expireHistory() {
    final cutoff = _now().subtract(const Duration(days: 30));
    for (final revisions in _revisions.values) {
      revisions.removeWhere((r) => !r.archivedAt.isAfter(cutoff));
    }
    for (final id in _recycled.keys.toList()) {
      final entry = _recycled[id]!.entry;
      if (!entry.expiresAt.isAfter(_now())) {
        _recycled.remove(id);
        _forgetContent(entry.record.ref);
      }
    }
  }

  void _ordinary(WorkspaceRecordRef ref) {
    if (ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '凭据通过专用生命周期流程管理。');
    }
  }

  WorkspaceDetail _current(WorkspaceRecordRef ref) {
    _ordinary(ref);
    final current = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[ref];
    if (current == null) {
      throw const WorkspaceFailure('not_found', '资料已不存在，请先检查回收站。');
    }
    return current;
  }

  WorkspaceDetail _normalizeArchive(
    WorkspaceArchive archive,
    int version,
    List<String> notices,
  ) {
    final old = archive.detail;
    final directory = old.record.directoryId;
    final missingDirectory =
        directory != null &&
        !_catalog.directories.any((d) => d.id == directory);
    final currentTags = {for (final tag in _catalog.tags) tag.id: tag};
    final tags = [for (final tag in old.record.tags) ?currentTags[tag.id]];
    if (missingDirectory) notices.add('原目录已移除，恢复后归入未分类。');
    if (tags.length != old.record.tags.length) notices.add('已移除的标签不会恢复。');
    final relations = <String, List<WorkspaceRecordRef>>{};
    for (final entry in old.relations.entries) {
      final rule = _relationRule(old.definition, entry.key);
      relations[entry.key] = [
        for (final ref in entry.value)
          if (_records[ref] case final target?
              when rule != null && _acceptsRelation(rule, target.record))
            ref,
      ];
      if (relations[entry.key]!.length != entry.value.length) {
        notices.add('“${entry.key}”中失效的关联不会恢复。');
      }
    }
    return WorkspaceDetail(
      record: old.record.copyWith(
        unfiled: missingDirectory,
        tags: tags,
        updatedAt: _now(),
      ),
      version: version,
      definition: old.definition,
      values: old.values,
      relations: relations,
    );
  }
}

// Public methods live on the provider rather than on widgets so every library
// projection observes the same transitions and failure/idempotency policy.
extension _SampleWorkspaceHistory on SampleWorkspaceSource {
  Future<List<WorkspaceRevision>> _loadRevisions(WorkspaceRecordRef ref) async {
    await _readable();
    _current(ref);
    return List.unmodifiable([
      for (final r in (_revisions[ref] ?? <WorkspaceArchive>[]).reversed)
        WorkspaceRevision(r.detail.record, r.detail.version, r.archivedAt),
    ]);
  }

  Future<WorkspaceRevisionPreview> _previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) async {
    await _readable();
    return _buildRevisionPreview(
      ref,
      version,
      expectedVersion: expectedVersion,
    );
  }

  WorkspaceRevisionPreview _buildRevisionPreview(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) {
    final current = _current(ref);
    if (current.version != expectedVersion) {
      throw const WorkspaceFailure('conflict', '资料已更新，请重新读取并比较。');
    }
    final archive = _revisions[ref]
        ?.where((r) => r.detail.version == version)
        .firstOrNull;
    if (archive == null) {
      throw const WorkspaceFailure('not_found', '历史版本已到期或不可用。');
    }
    final notices = <String>[];
    final restored = _normalizeArchive(archive, current.version + 1, notices);
    return WorkspaceRevisionPreview(
      current: current,
      archive: archive,
      restored: restored,
      catalogVersion: _catalogVersion,
      notices: notices,
      missingFields: archive.detail.values.keys.where(
        (k) => !current.values.containsKey(k),
      ),
    );
  }

  Future<WorkspaceRecycleResults> _queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) async {
    await _readable();
    if (offset < 0 || limit < 1 || limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的回收站分页范围。');
    }
    final entries =
        [
          if (_scenario != SampleWorkspaceScenario.empty)
            for (final r in _recycled.values)
              if (_matchesKeyword(r.entry.record, keyword)) r.entry,
        ]..sort((a, b) {
          final time = b.deletedAt.compareTo(a.deletedAt);
          return time != 0 ? time : a.id.compareTo(b.id);
        });
    final start = _pageOffset(offset, limit, entries.length);
    return WorkspaceRecycleResults(
      items: entries.skip(start).take(limit),
      total: entries.length,
      offset: start,
    );
  }

  Future<WorkspaceArchive> _readRecycled(String entryId) async {
    await _readable();
    final archive = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _recycled[entryId]?.archive;
    if (archive == null) {
      throw const WorkspaceFailure('not_found', '回收内容已恢复、清理或到期。');
    }
    return archive;
  }

  Future<WorkspaceRecordReceipt> _changeRecord(
    WorkspaceRecordChange change,
  ) async {
    await _readable();
    final epoch = _epoch;
    _ordinary(change.ref);
    final fingerprint = _fingerprint({
      'action': change.action.name,
      'ref': change.ref.key,
      'version': change.expectedVersion,
      'revision': change.revisionVersion,
      'entry': change.entryId,
      'catalog': change.expectedCatalogVersion,
    });
    if (change.operationId.trim().isEmpty) {
      throw const WorkspaceFailure('validation', '操作身份不能为空。');
    }
    final previous = _recordOperations[change.operationId];
    if (previous != null) {
      if (previous.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return previous.receipt;
    }
    final ref = change.ref;
    final notices = <String>[];
    WorkspaceDetail? restored;
    WorkspaceArchive? archive;
    String? entryId;
    var version = change.expectedVersion + 1;
    switch (change.action) {
      case WorkspaceRecordAction.recycle:
      case WorkspaceRecordAction.restoreRevision:
        final current = _current(ref);
        if (current.version != change.expectedVersion) {
          throw const WorkspaceFailure('conflict', '资料已更新，请重新读取并核对。');
        }
        archive = _archive(current);
        if (change.action == WorkspaceRecordAction.restoreRevision) {
          final preview = _buildRevisionPreview(
            ref,
            change.revisionVersion ?? -1,
            expectedVersion: change.expectedVersion,
          );
          if (!preview.canRestore) {
            throw const WorkspaceFailure(
              'recycle_restore_required',
              '旧版本包含已移除的字段，请先显式恢复回收内容。',
            );
          }
          restored = preview.restored;
          notices.addAll(preview.notices);
        }
      case WorkspaceRecordAction.restoreRecycled:
      case WorkspaceRecordAction.purge:
        final recycled = _scenario == SampleWorkspaceScenario.empty
            ? null
            : _recycled[change.entryId];
        if (recycled == null || recycled.entry.record.ref != ref) {
          throw const WorkspaceFailure('not_found', '回收内容已恢复、清理或到期。');
        }
        if (recycled.entry.version != change.expectedVersion) {
          throw const WorkspaceFailure('conflict', '回收内容已变化，请重新读取。');
        }
        if (change.action == WorkspaceRecordAction.restoreRecycled) {
          if (_records.containsKey(ref)) {
            throw const WorkspaceFailure('conflict', '资料已存在，请刷新后核对。');
          }
          version = (_versions[ref] ?? recycled.entry.version) + 1;
          restored = _normalizeArchive(recycled.archive, version, notices);
        }
        entryId = recycled.entry.id;
    }
    if (epoch != _epoch) {
      throw const WorkspaceFailure('cancelled', '预览状态已变化，请重新读取。');
    }
    if ((change.action == WorkspaceRecordAction.recycle ||
            change.action == WorkspaceRecordAction.restoreRevision) &&
        _records[ref]?.version != change.expectedVersion) {
      throw const WorkspaceFailure('conflict', '资料已更新，请重新读取并核对。');
    }
    if (restored != null && change.expectedCatalogVersion != _catalogVersion) {
      throw const WorkspaceFailure('conflict', '目录或标签已变化，请重新读取并核对恢复范围。');
    }
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
    // No awaits after validation: the mutation, history and receipt commit as
    // one in-memory transition. A failed command changes none of them.
    switch (change.action) {
      case WorkspaceRecordAction.recycle:
        entryId = 'preview-recycle-${++_nextRecycle}';
        final now = _now();
        _recycled[entryId] = (
          entry: WorkspaceRecycleEntry(
            id: entryId,
            record: archive!.detail.record,
            version: version,
            deletedAt: now,
            expiresAt: now.add(const Duration(days: 30)),
            directoryName: archive.directoryName,
          ),
          archive: archive,
        );
        _records.remove(ref);
      case WorkspaceRecordAction.restoreRevision:
        (_revisions[ref] ??= []).add(archive!);
        _records[ref] = restored!;
      case WorkspaceRecordAction.restoreRecycled:
        _recycled.remove(entryId);
        _records[ref] = restored!;
      case WorkspaceRecordAction.purge:
        _recycled.remove(entryId);
        _forgetContent(ref);
    }
    _versions[ref] = version;
    final receipt = WorkspaceRecordReceipt(
      ref: ref,
      version: version,
      entryId: entryId,
      notices: notices,
    );
    _recordOperations[change.operationId] = (
      fingerprint: fingerprint,
      receipt: receipt,
    );
    _changes.add(ref);
    return receipt;
  }
}
