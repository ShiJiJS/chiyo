part of 'info_core.dart';

extension OwnerRevisions on OwnerAccess {
  String _currentRevisionFieldId(
    String itemId,
    String original,
    InformationItem current,
  ) {
    var id = original;
    final seen = <String>{};
    final links = <String, Set<String>>{};
    for (final fact in recycleFacts.where(
      (f) => f.itemId == itemId && f.kind == RecycleFactKind.restored,
    )) {
      for (final entry in fact.restoredFieldIds.entries) {
        links.putIfAbsent(entry.key, () => <String>{}).add(entry.value);
      }
    }
    while (seen.length <= 10000 && seen.add(id)) {
      if (current.fields.any((f) => f.id == id)) return id;
      final next = links[id];
      if (next == null) return original;
      if (next.length != 1) throw const AccessFailure('revision_conflict');
      id = next.single;
    }
    throw const AccessFailure('revision_conflict');
  }

  Future<List<InformationRevision>> revisionsFor(String itemId) =>
      _serialize(() async {
        await _purgeRevisions();
        final result = informationRevisions
            .where((r) => r.item.id == itemId)
            .toList();
        result.sort((a, b) => b.item.version.compareTo(a.item.version));
        return List.unmodifiable(result);
      });

  RevisionPreview previewRevision(
    String itemId,
    int revisionVersion,
    int expectedVersion,
  ) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final current = information.where((i) => i.id == itemId).firstOrNull;
    if (current == null) throw const AccessFailure('recycle_restore_required');
    if (current.version != expectedVersion) {
      throw const AccessFailure('revision_conflict');
    }
    final revision = informationRevisions
        .where((r) => r.item.id == itemId && r.item.version == revisionVersion)
        .firstOrNull;
    if (revision == null) throw const AccessFailure('revision_unavailable');
    final old = revision.item;
    final resolved = {
      for (final f in old.fields)
        f.id: _currentRevisionFieldId(itemId, f.id, current),
    };
    if (resolved.values.toSet().length != resolved.length) {
      throw const AccessFailure('revision_conflict');
    }
    final restored = InformationItem(
      current.id,
      old.name,
      old.description,
      current.version + 1,
      [
        for (final f in old.fields)
          f.withMetadata(
            id: resolved[f.id]!,
            version:
                max(
                  f.version,
                  current.fields
                          .where((c) => c.id == resolved[f.id])
                          .firstOrNull
                          ?.version ??
                      0,
                ) +
                1,
          ),
      ],
      directoryId: _existingDirectory(old.directoryId),
      tagIds: _existingTags(old.tagIds),
      layout: _existingLayoutRelations(old.layout?.remapFields(resolved)),
      createdAt: current.createdAt,
      modifiedAt: _service._clock(),
    );
    return RevisionPreview(revision, current, restored);
  }

  Future<InformationItem> restoreRevision(
    String itemId,
    int revisionVersion,
    int expectedVersion,
  ) => _serialize(
    () => _restoreRevision(itemId, revisionVersion, expectedVersion),
  );

  Future<InformationItem> _restoreRevision(
    String itemId,
    int revisionVersion,
    int expectedVersion, {
    InformationLifecycleCommand? command,
    void Function()? validate,
  }) async {
    await _purgeRevisions();
    final preview = previewRevision(itemId, revisionVersion, expectedVersion);
    if (preview.requiresRecycleRestore) {
      throw const AccessFailure('recycle_restore_required');
    }
    final removed = preview.current.fields.any(
      (f) => !preview.restored.fields.any((c) => c.id == f.id),
    );
    final entry = removed ? _recycle(preview.current, preview.restored) : null;
    await _service._repository.commitRecycleChange(
      itemId: itemId,
      lifecycleReceipt: command == null
          ? null
          : InformationLifecycleReceipt(
              command: command,
              version: preview.restored.version,
              entryId: entry?.id,
            ),
      validate: validate,
      item: preview.restored,
      previous: InformationRevision(preview.current, _service._clock()),
      entries: entry == null ? const [] : [entry],
      facts: entry == null
          ? const []
          : [_fact(entry, RecycleFactKind.deleted, preview.restored.version)],
    );
    _invalidateRemoved(preview.current, preview.restored);
    return preview.restored;
  }

  Future<void> purgeRevisions() => _serialize(_purgeRevisions);
  Future<void> _purgeRevisions() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final now = _service._clock();
    await _service._repository.pruneInformationRevisions(
      now.subtract(const Duration(days: 30)),
      now,
    );
  }
}
