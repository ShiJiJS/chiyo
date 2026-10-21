part of 'info_core.dart';

extension AgentDeletes on AgentAccess {
  Future<String> submitDelete(
    String session,
    String itemId,
    int baseVersion, {
    String? fieldId,
  }) => _service.owner._serialize(() async {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session];
    if (binding == null) throw const AccessFailure('unauthorized');
    if (itemId.isEmpty ||
        itemId.length > 200 ||
        baseVersion < 1 ||
        (fieldId != null && (fieldId.isEmpty || fieldId.length > 200))) {
      throw const AccessFailure('invalid_proposal');
    }
    if (_service._repository.deleteProposals
            .where(
              (p) =>
                  p.sessionBinding == binding &&
                  p.state == DeleteProposalState.pending,
            )
            .length >=
        20) {
      throw const AccessFailure('proposal_limit');
    }
    final proposal = DeleteProposal(
      id: _service._secret(),
      sessionBinding: binding,
      chatLabel: _service._sessions[session]!,
      itemId: itemId,
      baseVersion: baseVersion,
      createdAt: _service._clock(),
      fieldId: fieldId,
    );
    await _service._repository.saveDeleteProposal(proposal);
    return proposal.id;
  });
  Map<String, Object?> deleteStatus(String session, String id) {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session];
    final found = _service._repository.deleteProposals.where(
      (p) => p.id == id && p.sessionBinding == binding,
    );
    if (binding == null || found.isEmpty) {
      throw const AccessFailure('unauthorized');
    }
    return {'status': found.single.state.name, 'proposalId': id};
  }
}

extension OwnerRecycle on OwnerAccess {
  List<DeleteProposal> get deleteProposals =>
      _service._repository.deleteProposals;
  DeleteProposal _deleteProposal(String id) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final found = deleteProposals.where((p) => p.id == id);
    if (found.isEmpty) throw const AccessFailure('proposal_changed');
    return found.single;
  }

  InformationItem previewDelete(String id) {
    final proposal = _deleteProposal(id);
    if (proposal.state != DeleteProposalState.pending) {
      throw const AccessFailure('proposal_changed');
    }
    final found = information.where((i) => i.id == proposal.itemId);
    if (found.isEmpty ||
        found.single.version != proposal.baseVersion ||
        (proposal.fieldId != null &&
            !found.single.fields.any((f) => f.id == proposal.fieldId))) {
      throw const AccessFailure('proposal_conflict');
    }
    return found.single;
  }

  Future<RecycleEntry> confirmDelete(String id, int proposalVersion) =>
      _serialize(() async {
        final proposal = _deleteProposal(id);
        if (proposal.state == DeleteProposalState.confirmed) {
          return _service._repository.recycleEntries.firstWhere(
            (e) => e.id == proposal.entryId,
          );
        }
        if (proposal.state != DeleteProposalState.pending ||
            proposal.version != proposalVersion) {
          throw const AccessFailure('proposal_changed');
        }
        try {
          previewDelete(id);
          return await _deleteInformation(
            proposal.itemId,
            proposal.baseVersion,
            fieldId: proposal.fieldId,
            proposal: proposal,
          );
        } on AccessFailure catch (error) {
          if (error.status == 'proposal_conflict') {
            await _service._repository.saveDeleteProposal(
              proposal.finish(DeleteProposalState.conflicted),
            );
          }
          rethrow;
        }
      });
  Future<void> rejectDelete(String id, int proposalVersion) =>
      _serialize(() async {
        final proposal = _deleteProposal(id);
        if (proposal.state != DeleteProposalState.pending ||
            proposal.version != proposalVersion) {
          throw const AccessFailure('proposal_changed');
        }
        await _service._repository.saveDeleteProposal(
          proposal.finish(DeleteProposalState.rejected),
        );
      });
  List<RecycleEntry> get recycleEntries => _service._repository.recycleEntries
      .where(
        (e) =>
            e.state == RecycleState.available &&
            _service._clock().isBefore(e.expiresAt),
      )
      .toList();
  List<RecycleFact> get recycleFacts => _service._repository.recycleFacts;

  RecycleEntry _recycle(InformationItem before, InformationItem? after) {
    final retained = after?.fields.map((f) => f.id).toSet() ?? <String>{};
    final removed = before.fields
        .where((f) => !retained.contains(f.id))
        .toList();
    final now = _service._clock();
    return RecycleEntry(
      id: _service._secret(),
      itemId: before.id,
      wholeItem: after == null,
      deletedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      version: before.version + 1,
      snapshot: InformationItem(
        before.id,
        before.name,
        before.description,
        before.version,
        removed,
        directoryId: before.directoryId,
        tagIds: before.tagIds,
        createdAt: before.createdAt,
        modifiedAt: before.modifiedAt,
      ),
    );
  }

  RecycleFact _fact(RecycleEntry entry, RecycleFactKind kind, int version) =>
      RecycleFact(
        entry.id,
        entry.itemId,
        entry.snapshot?.fields.map((f) => f.id) ?? const <String>[],
        version,
        kind,
        _service._clock(),
      );
  void _invalidateRemoved(InformationItem before, InformationItem? after) {
    final retained = after?.fields.map((f) => f.id).toSet() ?? <String>{};
    for (final field in before.fields.where((f) => !retained.contains(f.id))) {
      final ref = FieldRef(before.id, field.id);
      for (final request in _service._requests.values) {
        if (request.grant?.fields.contains(ref) ?? false) {
          request.invalidatedFields.add(ref);
        }
      }
    }
    _service._scheduleInformationDeliveryCleanup();
  }

  Future<RecycleEntry> deleteInformation(
    String itemId,
    int expectedVersion, {
    String? fieldId,
  }) => _serialize(
    () => _deleteInformation(itemId, expectedVersion, fieldId: fieldId),
  );
  Future<RecycleEntry> _deleteInformation(
    String itemId,
    int expectedVersion, {
    String? fieldId,
    DeleteProposal? proposal,
  }) async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final found = information.where((i) => i.id == itemId);
    if (found.isEmpty ||
        found.single.version != expectedVersion ||
        (fieldId != null && !found.single.fields.any((f) => f.id == fieldId))) {
      throw const AccessFailure('proposal_conflict');
    }
    final before = found.single;
    final remaining = before.fields.where((f) => f.id != fieldId).toList();
    final after = fieldId == null
        ? null
        : InformationItem(
            before.id,
            before.name,
            before.description,
            before.version + 1,
            remaining,
            directoryId: before.directoryId,
            tagIds: before.tagIds,
            createdAt: before.createdAt,
            modifiedAt: _service._clock(),
          );
    final entry = _recycle(before, after);
    await _service._repository.commitRecycleChange(
      itemId: itemId,
      item: after,
      previous: InformationRevision(before, _service._clock()),
      entries: [entry],
      facts: [_fact(entry, RecycleFactKind.deleted, entry.version)],
      proposal: proposal?.finish(
        DeleteProposalState.confirmed,
        entryId: entry.id,
      ),
    );
    _invalidateRemoved(before, after);
    return entry;
  }

  Future<InformationItem> restoreRecycled(String id) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    await _purgeRecycle();
    final found = recycleEntries.where((e) => e.id == id);
    if (found.isEmpty) throw const AccessFailure('recycle_unavailable');
    final entry = found.single;
    final snapshot = entry.snapshot!;
    final current = information.where((i) => i.id == entry.itemId);
    if ((entry.wholeItem && current.isNotEmpty) ||
        (!entry.wholeItem && current.isEmpty) ||
        (current.isNotEmpty &&
            snapshot.fields.any(
              (f) => current.single.fields.any((c) => c.id == f.id),
            ))) {
      throw const AccessFailure('recycle_conflict');
    }
    final previous = current.isEmpty ? null : current.single;
    final watermark = recycleFacts
        .where((f) => f.itemId == entry.itemId)
        .fold<int>(
          previous?.version ?? entry.version,
          (v, f) => max(v, f.version),
        );
    final source = previous ?? snapshot;
    final restoredIds = {
      for (final f in snapshot.fields) f.id: _service._secret(),
    };
    final restored = InformationItem(
      source.id,
      source.name,
      source.description,
      watermark + 1,
      [
        if (previous != null) ...previous.fields,
        for (final f in snapshot.fields)
          f.withMetadata(id: restoredIds[f.id]!, version: f.version + 1),
      ],
      directoryId: _existingDirectory(source.directoryId),
      tagIds: _existingTags(source.tagIds),
      createdAt: source.createdAt,
      modifiedAt: _service._clock(),
    );
    if (restored.fields.length > 200) {
      throw const AccessFailure('recycle_conflict');
    }
    await _service._repository.commitRecycleChange(
      itemId: restored.id,
      item: restored,
      previous: previous == null
          ? null
          : InformationRevision(previous, _service._clock()),
      entries: [entry.finish(RecycleState.restored)],
      facts: [
        RecycleFact(
          entry.id,
          entry.itemId,
          snapshot.fields.map((f) => f.id),
          restored.version,
          RecycleFactKind.restored,
          _service._clock(),
          restoredFieldIds: restoredIds,
        ),
      ],
    );
    return restored;
  });
  Future<void> purgeRecycle() => _serialize(_purgeRecycle);
  Future<void> _purgeRecycle() async {
    for (final entry in _service._repository.recycleEntries.where(
      (e) =>
          e.state == RecycleState.available &&
          !_service._clock().isBefore(e.expiresAt),
    )) {
      await _service._repository.commitRecycleChange(
        itemId: entry.itemId,
        item: information.where((i) => i.id == entry.itemId).firstOrNull,
        entries: [entry.finish(RecycleState.purged)],
        facts: [_fact(entry, RecycleFactKind.purged, entry.version)],
      );
    }
  }
}
