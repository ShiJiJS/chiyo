part of 'info_core.dart';

void _validateImport(List<ImportItemInput> items) {
  if (items.isEmpty ||
      items.length > 20 ||
      items.fold<int>(0, (n, i) => n + i.fields.length) > 200 ||
      utf8.encode(jsonEncode(items.map((i) => i.toJson()).toList())).length >
          240000 ||
      items.any(
        (i) =>
            i.name.trim().isEmpty ||
            i.name.length > 200 ||
            i.description.length > 2000 ||
            i.fields.isEmpty ||
            i.fields.length > 50 ||
            i.suggestedDirectory.length > 200 ||
            i.suggestedTemplate.length > 200 ||
            i.suggestedTags.length > 100 ||
            i.suggestedTags.any((t) => t.length > 200) ||
            i.tagIds.length > 100 ||
            i.tagIds.any((t) => t.length > 200) ||
            (i.directoryId != null && i.directoryId!.length > 200) ||
            i.fields.any(
              (f) =>
                  f.name.trim().isEmpty ||
                  f.name.length > 200 ||
                  f.description.length > 2000 ||
                  f.value.length > 64000,
            ),
      )) {
    throw const AccessFailure('invalid_proposal');
  }
}

extension AgentImports on AgentAccess {
  Future<String> submitImport(
    String session,
    List<ImportItemInput> items, {
    String agentName = '',
    String purpose = '',
  }) => _service.owner._serialize(() async {
    _service._requireSession(session);
    _validateImport(items);
    if (agentName.length > 200 || purpose.length > 2000) {
      throw const AccessFailure('invalid_proposal');
    }
    // Bound retained pending work per chat without revealing other sessions.
    if (_service._repository.importProposals
            .where(
              (p) =>
                  p.sessionBinding == _service._sessionBindings[session] &&
                  p.state == ImportProposalState.pending,
            )
            .length >=
        20) {
      throw const AccessFailure('proposal_limit');
    }
    final proposal = ImportProposal(
      id: _service._secret(),
      sessionBinding: _service._sessionBindings[session]!,
      chatLabel: _service._sessions[session]!,
      createdAt: _service._clock(),
      items: items,
      agentName: agentName.trim(),
      purpose: purpose.trim(),
    );
    await _service._repository.saveImportProposal(proposal);
    return proposal.id;
  });

  Map<String, Object?> importStatus(String session, String id) {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session];
    final matches = _service._repository.importProposals.where(
      (p) => p.id == id && p.sessionBinding == binding,
    );
    if (binding == null || matches.isEmpty) {
      throw const AccessFailure('unauthorized');
    }
    final proposal = matches.single;
    return {
      'status': proposal.state.name,
      'proposalId': proposal.id,
      'createdAt': proposal.createdAt.toUtc().toIso8601String(),
      if (proposal.state == ImportProposalState.confirmed)
        'itemIds': proposal.createdItemIds,
    };
  }
}

extension OwnerImports on OwnerAccess {
  List<ImportProposal> get importProposals =>
      _service._repository.importProposals;

  ImportProposal _pendingImport(String id, int version) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final matches = importProposals.where((p) => p.id == id);
    if (matches.isEmpty ||
        matches.single.state != ImportProposalState.pending ||
        matches.single.version != version) {
      throw const AccessFailure('proposal_changed');
    }
    return matches.single;
  }

  Future<List<ImportReceipt>> confirmImport(
    String id,
    int version,
    List<ImportItemInput> reviewed,
  ) => _serialize(() async {
    final found = importProposals.where((p) => p.id == id);
    if (found.isNotEmpty &&
        found.single.state == ImportProposalState.confirmed) {
      return found.single.receipts;
    }
    final previous = _pendingImport(id, version);
    _validateImport(reviewed);
    final confirmedAt = _service._clock();
    final organization = _OrganizationPlan(this);
    final locations = [
      for (final input in reviewed)
        organization.resolve(
          input.directoryId,
          input.tagIds,
          input.suggestedDirectory,
          input.suggestedTags,
        ),
    ];
    final items = [
      for (final (index, input) in reviewed.indexed)
        InformationItem(
          _service._secret(),
          input.name.trim(),
          input.description,
          1,
          [
            for (final f in input.fields)
              InformationField(
                _service._secret(),
                f.name.trim(),
                f.description,
                f.value,
                1,
                kind: f.kind,
              ),
          ],
          directoryId: locations[index].$1,
          tagIds: locations[index].$2,
          createdAt: confirmedAt,
          modifiedAt: confirmedAt,
        ),
    ];
    final confirmed = ImportProposal(
      id: previous.id,
      sessionBinding: previous.sessionBinding,
      chatLabel: previous.chatLabel,
      createdAt: previous.createdAt,
      items: reviewed,
      state: ImportProposalState.confirmed,
      version: previous.version + 1,
      createdItemIds: items.map((i) => i.id),
      createdItemVersions: items.map((i) => i.version),
      agentName: previous.agentName,
      purpose: previous.purpose,
      fieldCount: items.fold<int>(0, (n, i) => n + i.fields.length),
    );
    await _service._repository.confirmImportProposal(
      confirmed,
      items,
      newDirectories: organization.newDirectories,
      newTags: organization.newTags,
    );
    return confirmed.receipts;
  });

  Future<void> rejectImport(String id, int version) => _serialize(() async {
    final previous = _pendingImport(id, version);
    await _service._repository.saveImportProposal(
      ImportProposal(
        id: previous.id,
        sessionBinding: previous.sessionBinding,
        chatLabel: previous.chatLabel,
        createdAt: previous.createdAt,
        items: previous.items,
        state: ImportProposalState.rejected,
        version: previous.version + 1,
        agentName: previous.agentName,
        purpose: previous.purpose,
        fieldCount: previous.fieldCount,
      ),
    );
  });
}
