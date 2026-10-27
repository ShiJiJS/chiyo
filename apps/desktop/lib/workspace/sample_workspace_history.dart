part of 'sample_workspace_source.dart';

extension _SampleHistory on SampleWorkspaceSource {
  List<String> _missingEntryLeaves(
    WorkspaceDetail old,
    WorkspaceDetail current,
  ) {
    final active = <String, WorkspaceRepeatedEntry>{};
    for (final f in workspaceFields(
      current,
    ).where((f) => f['type'] == 'entries')) {
      try {
        for (final e in WorkspaceRepeatedEntry.read(current.values[f['key']])) {
          active[e.id] = e;
        }
      } on FormatException {
        /* Unknown current shapes confer no leaf identity. */
      }
    }
    final missing = <String>[];
    for (final f in workspaceFields(old).where((f) => f['type'] == 'entries')) {
      try {
        for (final e in WorkspaceRepeatedEntry.read(old.values[f['key']])) {
          // The existing whole-entry restore explicitly creates fresh entry
          // and leaf identities. Only retained entries could bind old content
          // to a replacement leaf's current identity.
          final retained = active[e.id];
          if (retained == null) continue;
          for (final part in e.activeParts) {
            if (retained.fieldIds[part] != e.fieldIds[part]) {
              missing.add('${f['key']}:${e.id}:$part');
            }
          }
        }
      } on FormatException {
        missing.add(f['key'] as String);
      }
    }
    return missing;
  }

  int _pageOffset(int offset, int limit, int total) =>
      total == 0 ? 0 : offset.clamp(0, (total - 1) ~/ limit * limit);

  WorkspaceArchive _archive(
    WorkspaceDetail detail, {
    DateTime? at,
    bool wholeItem = true,
  }) => WorkspaceArchive(
    detail: detail,
    wholeItem: wholeItem,
    archivedAt: at ?? _now(),
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
    _recycled.removeWhere((_, value) => value.entry.record.ref == ref);
    if (ref.kind == WorkspaceRecordKind.credential) _credentials.forget(ref);
    _revisions.remove(ref);
    _adoptionPlans.removeWhere((_, p) => p.current.record.ref == ref);
    _files.forget(ref);
    for (final credential in _credentialLinks.credentials(ref).toList()) {
      if (_records[credential] case final raw?) {
        _records[credential] = WorkspaceDetail(
          record: raw.record.copyWith(updatedAt: _now()),
          version: raw.version + 1,
          definition: raw.definition,
          fieldIds: raw.fieldIds,
          fieldOverrides: raw.fieldOverrides,
          retainedFields: raw.retainedFields,
          retainedRelations: raw.retainedRelations,
          values: raw.values,
          relations: raw.relations,
        );
        _versions[credential] = raw.version + 1;
      }
    }
    _credentialLinks.forgetInformation(ref);
    // File receipts contain only opaque identities/result facts, no content.
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

  void _forgetPartialHistory(WorkspaceArchive removed) {
    final ref = removed.detail.record.ref;
    Set<String> ids(WorkspaceDetail d) => {
      ...d.fieldIds.values,
      for (final f in workspaceFields(d).where((f) => f['type'] == 'entries'))
        for (final entry in WorkspaceRepeatedEntry.read(d.values[f['key']]))
          ...entry.fieldIds.values,
    };
    final erased = ids(removed.detail);
    bool contains(WorkspaceDetail d) =>
        d.record.ref == ref && ids(d).any(erased.contains);
    _revisions[ref]?.removeWhere((a) => contains(a.detail));
    _adoptionPlans.removeWhere(
      (_, p) => contains(p.current) || contains(p.result),
    );
    for (final id in _operations.keys.toList()) {
      final op = _operations[id]!;
      if (op.result case WorkspaceSaved(:final detail) when contains(detail)) {
        _operations[id] = (
          fingerprint: op.fingerprint,
          result: const WorkspaceRejected(
            WorkspaceFailure('purged', '旧内容已清理，请读取当前资料。'),
          ),
        );
      }
    }
  }

  void _expireHistory() {
    _credentials.expireMaterials();
    final cutoff = _now().subtract(const Duration(days: 30));
    for (final revisions in _revisions.values) {
      revisions.removeWhere((r) => !r.archivedAt.isAfter(cutoff));
    }
    for (final id in _recycled.keys.toList()) {
      final retained = _recycled[id];
      if (retained == null) continue;
      final entry = retained.entry;
      if (!entry.expiresAt.isAfter(_now())) {
        _recycled.remove(id);
        if (entry.wholeItem) {
          _forgetContent(entry.record.ref);
        } else {
          _forgetPartialHistory(retained.archive);
        }
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
    return _projectRecord(current);
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
      final rule = _relationRule(workspaceEditingDefinition(old), entry.key);
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
      fieldIds: sampleRestoredFieldIds(old, _records[old.record.ref], version),
      fieldOverrides: old.fieldOverrides,
      retainedFields: old.retainedFields,
      retainedRelations: old.retainedRelations,
      values: _files.restoredValues(
        old,
        _records[old.record.ref],
        values: sampleRestoredEntries(old, _records[old.record.ref], version),
      ),
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
      missingFields: [
        ...archive.detail.values.keys.where(
          (k) => archive.detail.fieldIds[k] != null
              ? !current.fieldIds.values.contains(archive.detail.fieldIds[k])
              : !current.values.containsKey(k) &&
                    !current.retainedFields.any((f) => f['originKey'] == k),
        ),
        ..._missingEntryLeaves(archive.detail, current),
      ],
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
      'currentVersion': change.expectedCurrentVersion,
    });
    if (change.operationId.trim().isEmpty) {
      throw const WorkspaceFailure('validation', '操作身份不能为空。');
    }
    final previous = _recordOperations[change.operationId];
    if (_operations.containsKey(change.operationId)) {
      throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
    }
    if (previous != null) {
      if (previous.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return previous.receipt;
    }
    final ref = change.ref;
    final notices = <String>[];
    WorkspaceDetail? restored, fileRestoreOriginal;
    WorkspaceArchive? archive;
    String? entryId;
    var partial = false;
    WorkspaceArchive? partialArchive;
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
          fileRestoreOriginal = preview.archive.detail;
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
        partial = !recycled.entry.wholeItem;
        partialArchive = partial ? recycled.archive : null;
        if (change.action == WorkspaceRecordAction.restoreRecycled) {
          if (!partial && _records.containsKey(ref)) {
            throw const WorkspaceFailure('conflict', '资料已存在，请刷新后核对。');
          }
          if (partial) {
            final current = _current(ref);
            if (current.version != change.expectedCurrentVersion) {
              throw const WorkspaceFailure('conflict', '当前资料已变化，请重新核对要恢复的字段。');
            }
            version = current.version + 1;
            restored = _restorePartial(
              recycled.archive,
              current,
              version,
              change.operationId,
              notices,
            );
          } else {
            version = (_versions[ref] ?? recycled.entry.version) + 1;
            restored = _normalizeArchive(recycled.archive, version, notices);
            fileRestoreOriginal = recycled.archive.detail;
          }
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
    if (restored != null && fileRestoreOriginal != null) {
      _files.commitRestore(fileRestoreOriginal, restored, _now());
    }
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
        _putRecord(restored!);
      case WorkspaceRecordAction.restoreRecycled:
        _recycled.remove(entryId);
        if (partial) (_revisions[ref] ??= []).add(_archive(_current(ref)));
        _putRecord(restored!);
      case WorkspaceRecordAction.purge:
        _recycled.remove(entryId);
        if (partial) {
          _forgetPartialHistory(partialArchive!);
        } else {
          _forgetContent(ref);
        }
    }
    if (!(partial && change.action == WorkspaceRecordAction.purge)) {
      _versions[ref] = version;
    }
    if (restored != null) {
      _entryIdentityOwners.addAll(sampleEntryOwners(restored));
    }
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
    _recordCommitted(
      change.operationId,
      WorkspaceOperationIntent.change(change),
      receipt,
    );
    return receipt;
  }
}
