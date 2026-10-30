part of 'info_core.dart';

/// One atomic removal plan. Historical field identities determine the scope;
/// names and layout slots are never used to decide which content to erase.
final class InformationPurgeChange {
  InformationPurgeChange({
    required this.entryId,
    required this.itemId,
    required this.entryVersion,
    required this.currentVersion,
    required this.wholeItem,
    required this.at,
    required this.expired,
    required Iterable<String> fieldIds,
    required Iterable<RecycleEntry> entries,
    required Iterable<RecycleFact> facts,
    required Iterable<RevisionPurgeFact> revisions,
    required Iterable<UpdateProposal> updates,
    required Iterable<DeleteProposal> deletes,
    required Iterable<InformationAttachmentRef> attachments,
    required this.validate,
    this.receipt,
  }) : fieldIds = Set.unmodifiable(fieldIds),
       entries = List.unmodifiable(entries),
       facts = List.unmodifiable(facts),
       revisions = List.unmodifiable(revisions),
       updates = List.unmodifiable(updates),
       deletes = List.unmodifiable(deletes),
       attachments = Set.unmodifiable(attachments);
  final String entryId, itemId;
  final int entryVersion;
  final int? currentVersion;
  final bool wholeItem, expired;
  final DateTime at;
  final Set<String> fieldIds;
  final List<RecycleEntry> entries;
  final List<RecycleFact> facts;
  final List<RevisionPurgeFact> revisions;
  final List<UpdateProposal> updates;
  final List<DeleteProposal> deletes;
  final Set<InformationAttachmentRef> attachments;
  final InformationLifecycleReceipt? receipt;
  final void Function() validate;

  bool contains(InformationItem item) =>
      item.id == itemId &&
      (wholeItem || item.fields.any((f) => fieldIds.contains(f.id)));
  Iterable<InformationAttachmentRef> attachmentsIn(InformationItem item) =>
      item.id == itemId
      ? item.fields
            .where((f) => wholeItem || fieldIds.contains(f.id))
            .map((f) => f.attachment)
            .whereType<InformationAttachmentRef>()
      : const [];
}

abstract interface class InformationPurgeRepository {
  Future<void> commitInformationPurge(InformationPurgeChange change);
}

extension OwnerInformationPurge on OwnerAccess {
  Future<void> _purgeInformationEntry(
    RecycleEntry entry, {
    InformationLifecycleCommand? command,
    required bool expired,
  }) async {
    final repository = _service._repository;
    if (repository is! InformationPurgeRepository) {
      throw const AccessFailure('unsupported_capability');
    }
    final generation = _service._libraryGeneration;
    void validate() {
      if (!serviceAvailable) throw const AccessFailure('service_unavailable');
      if (generation != _service._libraryGeneration) {
        throw const AccessFailure('library_changed');
      }
    }

    validate();
    final now = _service._clock();
    final current = information.where((i) => i.id == entry.itemId).firstOrNull;
    final fields = entry.snapshot!.fields.map((f) => f.id).toSet();
    if (entry.state != RecycleState.available ||
        (expired
            ? now.isBefore(entry.expiresAt)
            : !now.isBefore(entry.expiresAt))) {
      throw const AccessFailure('recycle_unavailable');
    }
    if ((entry.wholeItem && current != null) ||
        (current != null && current.fields.any((f) => fields.contains(f.id))) ||
        (command != null &&
            (command.itemId != entry.itemId ||
                command.expectedVersion != entry.version ||
                command.expectedCurrentVersion != current?.version))) {
      throw const AccessFailure('recycle_conflict');
    }
    bool contains(InformationItem item) =>
        item.id == entry.itemId &&
        (entry.wholeItem || item.fields.any((f) => fields.contains(f.id)));
    final revisions = repository.informationRevisions
        .where((r) => contains(r.item))
        .toList();
    final entries = repository.recycleEntries
        .where((e) => e.snapshot != null && contains(e.snapshot!))
        .toList();
    final version =
        repository.recycleFacts
            .where((f) => f.itemId == entry.itemId)
            .fold<int>(
              max(entry.version, current?.version ?? 0),
              (v, f) => max(v, f.version),
            ) +
        1;
    final change = InformationPurgeChange(
      entryId: entry.id,
      itemId: entry.itemId,
      entryVersion: entry.version,
      currentVersion: current?.version,
      wholeItem: entry.wholeItem,
      fieldIds: fields,
      at: now,
      expired: expired,
      validate: validate,
      receipt: command == null
          ? null
          : InformationLifecycleReceipt(
              command: command,
              version: version,
              entryId: entry.id,
            ),
      entries: entries.map((e) => e.finish(RecycleState.purged)),
      facts: entries.map((e) => _fact(e, RecycleFactKind.purged, version)),
      revisions: revisions.map(
        (r) => RevisionPurgeFact(r.item.id, r.item.version, now),
      ),
      updates: repository.updateProposals
          .where(
            (p) =>
                p.state == UpdateProposalState.pending &&
                p.input.itemId == entry.itemId &&
                (entry.wholeItem ||
                    p.input.changes.any((c) => fields.contains(c.fieldId))),
          )
          .map((p) => p.finish(UpdateProposalState.conflicted)),
      deletes: repository.deleteProposals
          .where(
            (p) =>
                p.state == DeleteProposalState.pending &&
                p.itemId == entry.itemId &&
                (entry.wholeItem || fields.contains(p.fieldId)),
          )
          .map((p) => p.finish(DeleteProposalState.conflicted)),
      attachments: {
        for (final item in [
          entry.snapshot!,
          ...revisions.map((r) => r.item),
          ...entries.map((e) => e.snapshot!),
        ])
          for (final f in item.fields)
            if ((entry.wholeItem || fields.contains(f.id)) &&
                f.attachment != null)
              f.attachment!,
      },
    );
    await (repository as InformationPurgeRepository).commitInformationPurge(
      change,
    );
    _service._scheduleInformationDeliveryCleanup();
  }
}
