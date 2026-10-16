part of 'info_core.dart';

void _validateUpdate(UpdateInput input) {
  final touched = input.changes
      .map((c) => c.fieldId)
      .whereType<String>()
      .toList();
  if (input.itemId.isEmpty ||
      input.itemId.length > 200 ||
      input.baseVersion < 1 ||
      input.changes.length > 200 ||
      (input.changes.isEmpty &&
          input.name == null &&
          input.description == null) ||
      (input.name != null &&
          (input.name!.trim().isEmpty || input.name!.length > 200)) ||
      (input.description?.length ?? 0) > 2000 ||
      touched.toSet().length != touched.length ||
      touched.any((id) => id.isEmpty || id.length > 200) ||
      utf8.encode(jsonEncode(input.toJson())).length > 240000 ||
      input.changes.any(
        (c) =>
            (c.value?.length ?? 0) > 64000 ||
            (c.field != null &&
                (c.field!.name.trim().isEmpty ||
                    c.field!.name.length > 200 ||
                    c.field!.description.length > 2000 ||
                    c.field!.value.length > 64000)),
      )) {
    throw const AccessFailure('invalid_proposal');
  }
}

extension AgentUpdates on AgentAccess {
  Future<String> submitUpdate(
    String session,
    UpdateInput input,
  ) => _service.owner._serialize(() async {
    final binding = _service._sessionBindings[session];
    if (binding == null) throw const AccessFailure('unauthorized');
    _validateUpdate(input);
    if (_service._repository.updateProposals
            .where(
              (p) =>
                  p.sessionBinding == binding &&
                  p.state == UpdateProposalState.pending,
            )
            .length >=
        20) {
      throw const AccessFailure('proposal_limit');
    }
    // Target and version validation are deliberately owner-side: submission is
    // not an oracle for private values, existence, or unpublished proposals.
    final proposal = UpdateProposal(
      id: _service._secret(),
      sessionBinding: binding,
      chatLabel: _service._sessions[session]!,
      createdAt: _service._clock(),
      input: input,
    );
    await _service._repository.saveUpdateProposal(proposal);
    return proposal.id;
  });
  Map<String, Object?> updateStatus(String session, String id) {
    final binding = _service._sessionBindings[session];
    final found = _service._repository.updateProposals.where(
      (p) => p.id == id && p.sessionBinding == binding,
    );
    if (binding == null || found.isEmpty) {
      throw const AccessFailure('unauthorized');
    }
    return {'status': found.single.state.name, 'proposalId': id};
  }
}

extension OwnerUpdates on OwnerAccess {
  List<UpdateProposal> get updateProposals =>
      _service._repository.updateProposals;
  List<InformationRevision> get informationRevisions =>
      _service._repository.informationRevisions;
  UpdateProposal _update(String id) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final found = updateProposals.where((p) => p.id == id);
    if (found.isEmpty) throw const AccessFailure('proposal_changed');
    return found.single;
  }

  UpdatePreview previewUpdate(String id) {
    final proposal = _update(id);
    if (proposal.state != UpdateProposalState.pending) {
      throw const AccessFailure('proposal_changed');
    }
    final found = information.where((i) => i.id == proposal.input.itemId);
    if (found.isEmpty || found.single.version != proposal.input.baseVersion) {
      throw const AccessFailure('proposal_conflict');
    }
    return UpdatePreview(
      proposal,
      found.single,
      _applyUpdate(found.single, proposal.input),
    );
  }

  InformationItem _applyUpdate(InformationItem previous, UpdateInput input) {
    _validateUpdate(input);
    final fields = previous.fields.toList();
    for (final change in input.changes) {
      final index = fields.indexWhere((f) => f.id == change.fieldId);
      if (change.kind != FieldChangeKind.add && index < 0) {
        throw const AccessFailure('proposal_conflict');
      }
      switch (change.kind) {
        case FieldChangeKind.correct:
          final old = fields[index];
          fields[index] = InformationField(
            old.id,
            old.name,
            old.description,
            change.value!,
            old.version + 1,
            kind: old.kind,
          );
        case FieldChangeKind.remove:
          fields.removeAt(index);
        case FieldChangeKind.add:
        case FieldChangeKind.replace:
          final f = change.field!;
          final added = InformationField(
            _service._secret(),
            f.name.trim(),
            f.description,
            f.value,
            1,
            kind: f.kind,
          );
          if (change.kind == FieldChangeKind.add) {
            fields.add(added);
          } else {
            fields[index] = added;
          }
      }
    }
    if (fields.isEmpty || fields.length > 200) {
      throw const AccessFailure('invalid_proposal');
    }
    return InformationItem(
      previous.id,
      input.name?.trim() ?? previous.name,
      input.description ?? previous.description,
      previous.version + 1,
      fields,
      directoryId: previous.directoryId,
      tagIds: previous.tagIds,
    );
  }

  Future<UpdateReceipt> confirmUpdate(String id, int proposalVersion) =>
      _serialize(() async {
        final proposal = _update(id);
        if (proposal.state == UpdateProposalState.confirmed) {
          return proposal.result!;
        }
        if (proposal.state != UpdateProposalState.pending ||
            proposal.version != proposalVersion) {
          throw const AccessFailure('proposal_changed');
        }
        UpdatePreview preview;
        try {
          preview = previewUpdate(id);
        } on AccessFailure catch (error) {
          if (error.status == 'proposal_conflict') {
            await _service._repository.saveUpdateProposal(
              proposal.finish(UpdateProposalState.conflicted),
            );
          }
          rethrow;
        }
        final item = preview.after;
        final receipt = UpdateReceipt(item.id, item.version);
        final removed = preview.before.fields.any(
          (f) => !item.fields.any((n) => n.id == f.id),
        );
        final recycled = removed ? _recycle(preview.before, item) : null;
        await _service._repository.confirmUpdateProposal(
          proposal.finish(UpdateProposalState.confirmed, result: receipt),
          item,
          InformationRevision(preview.before, _service._clock()),
          recycled: recycled == null ? const [] : [recycled],
          facts: recycled == null
              ? const []
              : [_fact(recycled, RecycleFactKind.deleted, item.version)],
        );
        _invalidateRemoved(preview.before, item);
        return receipt;
      });
  Future<void> rejectUpdate(String id, int proposalVersion) =>
      _serialize(() async {
        final proposal = _update(id);
        if (proposal.state != UpdateProposalState.pending ||
            proposal.version != proposalVersion) {
          throw const AccessFailure('proposal_changed');
        }
        await _service._repository.saveUpdateProposal(
          proposal.finish(UpdateProposalState.rejected),
        );
      });
}
