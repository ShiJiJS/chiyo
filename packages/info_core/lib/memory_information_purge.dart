part of 'information.dart';

extension _MemoryInformationPurge on MemoryInformationRepository {
  void _commitPurge(InformationPurgeChange change) {
    change.validate();
    final entry = _recycle[change.entryId];
    if (entry == null ||
        entry.state != RecycleState.available ||
        entry.snapshot == null ||
        (change.expired
            ? change.at.isBefore(entry.expiresAt)
            : !change.at.isBefore(entry.expiresAt))) {
      throw const AccessFailure('recycle_unavailable');
    }
    final current = _items[change.itemId];
    if (entry.itemId != change.itemId ||
        entry.version != change.entryVersion ||
        entry.wholeItem != change.wholeItem ||
        current?.version != change.currentVersion ||
        (change.wholeItem && current != null) ||
        (current != null && change.contains(current))) {
      throw const AccessFailure('recycle_conflict');
    }
    if (change.receipt case final receipt?) {
      if (_lifecycleReceipts.containsKey(receipt.command.operationId)) {
        throw const AccessFailure('operation_conflict');
      }
      if (receipt.command.expectedCatalogVersion != null &&
          _classificationVersion() != receipt.command.expectedCatalogVersion) {
        throw const AccessFailure('organization_conflict');
      }
    }
    final commits = _informationCommits.entries
        .where((e) => change.contains(e.value.item))
        .toList();
    final candidates = {
      ...change.attachments,
      for (final e in commits) ...change.attachmentsIn(e.value.item),
    };
    final removedVersions = change.revisions.map((r) => r.version).toSet();
    final removedEntries = change.entries.map((e) => e.id).toSet();
    final pinned = <InformationAttachmentRef>{
      for (final item in [
        ..._items.values,
        ..._revisions
            .where(
              (r) =>
                  r.item.id != change.itemId ||
                  !removedVersions.contains(r.item.version),
            )
            .map((r) => r.item),
        ..._recycle.values
            .where((e) => !removedEntries.contains(e.id))
            .map((e) => e.snapshot)
            .whereType<InformationItem>(),
      ])
        for (final field in item.fields)
          if (field.attachment != null) field.attachment!,
    };
    // Every check happens before changing in-memory state, matching the SQL
    // transaction's all-or-nothing visibility.
    change.validate();
    _revisions.removeWhere(
      (r) =>
          r.item.id == change.itemId &&
          removedVersions.contains(r.item.version),
    );
    for (final fact in change.revisions) {
      if (!_revisionPurges.any(
        (p) => p.itemId == fact.itemId && p.version == fact.version,
      )) {
        _revisionPurges.add(fact);
      }
    }
    for (final e in change.entries) {
      _recycle[e.id] = e;
    }
    _recycleFacts.addAll(change.facts);
    for (final p in change.updates) {
      _updates[p.id] = p;
    }
    for (final p in change.deletes) {
      _deletes[p.id] = p;
    }
    for (final e in commits) {
      _informationCommits.remove(e.key);
      _purgedInformationCommits.add(e.key);
    }
    for (final ref in candidates.difference(pinned)) {
      final value = _informationFiles[ref];
      if (value != null && value.$1.available) {
        _informationFiles[ref] = (
          value.$1.withRetention(
            retiredAt: value.$1.retiredAt ?? change.at.toUtc(),
            purgedAt: change.at.toUtc(),
          ),
          null,
        );
      }
    }
    _reconcileInformationFiles(change.at);
    if (change.receipt case final receipt?) {
      _lifecycleReceipts[receipt.command.operationId] = receipt;
    }
  }
}
