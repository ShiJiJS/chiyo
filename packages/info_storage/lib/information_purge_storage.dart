part of 'info_storage.dart';

extension _EncryptedInformationPurge on EncryptedInformationRepository {
  Future<void> _commitInformationPurge(InformationPurgeChange change) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(() async {
        change.validate();
        final rows = await _db
            .customSelect(
              'SELECT payload FROM recycle_entries WHERE id=?',
              variables: [Variable(change.entryId)],
            )
            .get();
        if (rows.isEmpty) throw const AccessFailure('recycle_unavailable');
        final entry = RecycleEntry.fromJson(
          jsonDecode(rows.single.read<String>('payload'))
              as Map<String, dynamic>,
        );
        if (entry.state != RecycleState.available ||
            entry.snapshot == null ||
            (change.expired
                ? change.at.isBefore(entry.expiresAt)
                : !change.at.isBefore(entry.expiresAt)))
          throw const AccessFailure('recycle_unavailable');
        final current = await _db
            .customSelect(
              'SELECT version FROM information_items WHERE id=?',
              variables: [Variable(change.itemId)],
            )
            .get();
        final currentVersion = current.isEmpty
            ? null
            : current.single.read<int>('version');
        final currentFields = await _db
            .customSelect(
              'SELECT id FROM information_fields WHERE item_id=?',
              variables: [Variable(change.itemId)],
            )
            .get();
        if (entry.itemId != change.itemId ||
            entry.version != change.entryVersion ||
            entry.wholeItem != change.wholeItem ||
            currentVersion != change.currentVersion ||
            (change.wholeItem && currentVersion != null) ||
            currentFields.any(
              (f) => change.fieldIds.contains(f.read<String>('id')),
            ))
          throw const AccessFailure('recycle_conflict');
        if (change.receipt case final receipt?) {
          if (await _lifecycleReceipt(receipt.command.operationId) != null)
            throw const AccessFailure('operation_conflict');
          if (receipt.command.expectedCatalogVersion != null &&
              await _classificationVersion() !=
                  receipt.command.expectedCatalogVersion)
            throw const AccessFailure('organization_conflict');
        }
        final candidates = {...change.attachments};
        // Old file-form commits contain complete snapshots. Leave a tombstone
        // at the same key so an active draft cannot replay or recreate them.
        for (final row
            in await _db
                .customSelect(
                  'SELECT draft_id,operation_id,payload FROM information_draft_commits',
                )
                .get()) {
          final payload =
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
          if (payload['purged'] == true) continue;
          final receipt = InformationDraftReceipt.fromPrivateJson(payload);
          if (!change.contains(receipt.item)) continue;
          candidates.addAll(change.attachmentsIn(receipt.item));
          await _db.customStatement(
            'UPDATE information_draft_commits SET payload=? WHERE draft_id=? AND operation_id=?',
            [
              jsonEncode({'purged': true}),
              row.read<String>('draft_id'),
              row.read<String>('operation_id'),
            ],
          );
        }
        for (final fact in change.revisions) {
          await _db.customStatement(
            'INSERT INTO revision_purge_facts(item_id,version,purged_at) VALUES(?,?,?) ON CONFLICT(item_id,version) DO NOTHING',
            [
              fact.itemId,
              fact.version,
              fact.purgedAt.toUtc().toIso8601String(),
            ],
          );
          await _db.customStatement(
            'DELETE FROM information_revisions WHERE item_id=? AND version=?',
            [fact.itemId, fact.version],
          );
        }
        if (await _hasRevisionSnapshots()) {
          for (final fact in change.revisions) {
            await _db.customStatement(
              'DELETE FROM information_revision_snapshots WHERE item_id=? AND version=?',
              [fact.itemId, fact.version],
            );
          }
        }
        await _writeRecycle(change.entries, change.facts);
        for (final proposal in change.updates) {
          await _writeUpdate(proposal);
        }
        for (final proposal in change.deletes) {
          await _writeDelete(proposal);
        }
        final pinned = <InformationAttachmentRef>{};
        void keep(InformationItem item) {
          pinned.addAll(
            item.fields
                .map((f) => f.attachment)
                .whereType<InformationAttachmentRef>(),
          );
        }

        for (final row
            in await _db
                .customSelect(
                  'SELECT attachment_id,attachment_version FROM information_file_fields',
                )
                .get()) {
          pinned.add(
            InformationAttachmentRef(
              row.read<String>('attachment_id'),
              row.read<int>('attachment_version'),
            ),
          );
        }
        for (final row
            in await _db
                .customSelect('SELECT payload FROM information_revisions')
                .get()) {
          keep(
            informationFromJson(
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
            ),
          );
        }
        for (final row
            in await _db
                .customSelect('SELECT payload FROM recycle_entries')
                .get()) {
          final snapshot = RecycleEntry.fromJson(
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          ).snapshot;
          if (snapshot != null) keep(snapshot);
        }
        for (final ref in candidates.difference(pinned)) {
          final version = await _attachmentVersion(ref);
          if (version == null || !version.available) continue;
          final purged = version.withRetention(
            retiredAt: version.retiredAt ?? change.at.toUtc(),
            purgedAt: change.at.toUtc(),
          );
          await _db.customStatement(
            'UPDATE information_attachment_versions SET metadata=?,body=NULL WHERE attachment_id=? AND version=?',
            [
              jsonEncode(purged.toPrivateJson()),
              ref.attachmentId,
              ref.attachmentVersion,
            ],
          );
        }
        if (change.receipt case final receipt?) {
          await _db.customStatement(
            'INSERT INTO information_lifecycle_operations(operation_id,payload) VALUES(?,?)',
            [receipt.command.operationId, jsonEncode(receipt.toJson())],
          );
        }
        await _checkAttachmentBackupBudget();
        change.validate();
      });
      final versions = change.revisions.map((r) => r.version).toSet();
      _revisions.removeWhere(
        (r) => r.item.id == change.itemId && versions.contains(r.item.version),
      );
      for (final fact in change.revisions) {
        if (!_revisionPurges.any(
          (p) => p.itemId == fact.itemId && p.version == fact.version,
        ))
          _revisionPurges.add(fact);
      }
      for (final entry in change.entries) {
        _recycle[entry.id] = entry;
      }
      _recycleFacts.addAll(change.facts);
      for (final proposal in change.updates) {
        _updates[proposal.id] = proposal;
      }
      for (final proposal in change.deletes) {
        _deletes[proposal.id] = proposal;
      }
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('information_purge_failed');
    }
  }
}
