part of 'info_core.dart';

void _validateImport(List<ImportItemInput> items) {
  bool invalidRelations(ImportItemInput input) {
    for (final group in {
      ...input.relations.keys,
      ...input.pendingRelations.keys,
    }) {
      final targets = [
        for (final ref in input.relations[group] ?? <InformationRelationRef>[])
          jsonEncode(ref.toJson()),
        for (final ref
            in input.pendingRelations[group] ?? <ImportPendingReference>[])
          jsonEncode(ref.toJson()),
      ];
      if (targets.length > 200 || targets.toSet().length != targets.length) {
        return true;
      }
    }
    return false;
  }

  if (items.isEmpty ||
      items.length > 20 ||
      items.fold<int>(0, (n, i) => n + i.fields.length + i.attachments.length) >
          200 ||
      utf8
              .encode(jsonEncode(items.map((i) => i.submissionJson).toList()))
              .length >
          (items.any((i) => i.credential != null) ? 6000000 : 240000) ||
      items.any(
        (i) =>
            i.name.trim().isEmpty ||
            i.name.length > 200 ||
            i.description.length > 2000 ||
            invalidRelations(i) ||
            i.key.isNotEmpty &&
                !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(i.key) ||
            i.fields.isEmpty && i.templateId == null ||
            i.templateId == null &&
                (i.values.isNotEmpty ||
                    i.layout != null ||
                    i.relations.isNotEmpty ||
                    i.pendingRelations.isNotEmpty) ||
            i.credential != null && i.templateId == null ||
            i.attachments.isNotEmpty &&
                (i.templateId == null || i.credential != null) ||
            i.attachments.any((a) => a.fieldId != null) ||
            i.attachments.map((a) => a.key).toSet().length !=
                i.attachments.length ||
            i.attachments.fold<int>(0, (n, a) => n + a.versions.length) > 200 ||
            i.fields.length + i.attachments.length > 50 ||
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
  Map<String, Object?> importStatusByOperation(
    String session,
    String operationId,
  ) {
    _service._requireSession(session);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(operationId)) {
      throw const AccessFailure('invalid_operation_id');
    }
    final proposal = _service._repository.importProposals
        .where(
          (p) =>
              p.sessionBinding == _service._sessionBindings[session] &&
              p.operationId == operationId,
        )
        .firstOrNull;
    return proposal == null
        ? {'status': 'not_found', 'operationId': operationId}
        : importStatus(session, proposal.id);
  }

  Future<void> reviseImport(
    String session,
    String id,
    int version,
    List<ImportItemInput> revised,
  ) => _service.owner._serialize(() async {
    _service._requireSession(session);
    final old = _service._repository.importProposals
        .where(
          (p) =>
              p.id == id &&
              p.sessionBinding == _service._sessionBindings[session],
        )
        .firstOrNull;
    if (old == null) throw const AccessFailure('unauthorized');
    if (old.state != ImportProposalState.pending || old.version != version) {
      throw const AccessFailure('proposal_changed');
    }
    _validateImport(revised);
    if (revised.map((i) => i.key).toSet().length != revised.length ||
        revised.any(
          (i) => i.key.isEmpty || !old.items.any((o) => o.key == i.key),
        )) {
      throw const AccessFailure('invalid_proposal');
    }
    revised = await _service.owner._resolveImportFiles(
      old.sessionBinding,
      revised,
    );
    revised = _service.owner._compileTemplateImports(revised);
    _validateImport(revised);
    final changes = {for (final i in revised) i.key: i};
    final next = old.revise(
      items: [for (final i in old.items) changes[i.key] ?? i],
      approvedKeys: old.approvedKeys.where((k) => !changes.containsKey(k)),
    );
    _service.owner._validatePendingImportTargets(next, revised);
    await _service._repository.saveImportProposal(next);
  });

  Future<String> submitImport(
    String session,
    List<ImportItemInput> items, {
    String agentName = '',
    String title = '',
    String externalChatId = '',
    String purpose = '',
    String? operationId,
  }) => _service.owner._serialize(() async {
    _service._requireSession(session);
    _validateImport(items);
    if (operationId != null &&
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
        ).hasMatch(operationId!)) {
      throw const AccessFailure('invalid_operation_id');
    }
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'items': [for (final i in items) i.submissionJson],
              'purpose': purpose,
              'agentName': agentName,
              if (title.isNotEmpty) 'title': title,
              if (externalChatId.isNotEmpty) 'externalChatId': externalChatId,
            }),
          ),
        )
        .toString();
    operationId ??= items.any((i) => i.credential != null)
        ? 'credential-$digest'
        : null;
    if (operationId != null) {
      final previous = _service._repository.importProposals
          .where(
            (p) =>
                p.sessionBinding == _service._sessionBindings[session] &&
                p.operationId == operationId,
          )
          .firstOrNull;
      if (previous != null) {
        if (previous.submissionDigest != digest) {
          throw const AccessFailure('operation_conflict');
        }
        return previous.id;
      }
    }
    items = await _service.owner._resolveImportFiles(
      _service._sessionBindings[session]!,
      items,
    );
    items = _service.owner._compileTemplateImports(items);
    _validateImport(items);
    if (!validSubmissionMetadata(
      title: title,
      agentName: agentName,
      purpose: purpose,
      externalChatId: externalChatId,
    )) {
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
      title: title.trim(),
      externalChatId: externalChatId.trim(),
      purpose: purpose.trim(),
      operationId: operationId,
      submissionDigest: operationId == null ? null : digest,
    );
    if (proposal.items.map((i) => i.key).toSet().length !=
        proposal.items.length) {
      throw const AccessFailure('invalid_proposal');
    }
    _service.owner._validatePendingImportTargets(proposal, proposal.items);
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
    final states = _service.owner.importAdmission(id);
    return {
      'status':
          proposal.state == ImportProposalState.pending &&
              states.any((s) => s.state == 'needs_attention')
          ? 'needs_attention'
          : proposal.awaitingAdmission
          ? 'approved_awaiting_admission'
          : proposal.state.name,
      'proposalId': proposal.id,
      if (proposal.title.isNotEmpty) 'title': proposal.title,
      'createdAt': proposal.createdAt.toUtc().toIso8601String(),
      'version': proposal.version,
      'items': [
        for (final state in states)
          {
            'key': state.key,
            'state': state.state,
            if (proposal.candidateKinds[state.key] == 'credential')
              'kind': 'credential',
            if (proposal.receiptFor(state.key) case final receipt?) ...{
              'itemId': receipt.id,
              'version': receipt.version,
              if (proposal.admissionDirectories[state.key] case final location?)
                'savedLocation': location.toJson(),
            },
          },
      ],
      if (proposal.state == ImportProposalState.confirmed)
        'itemIds': proposal.createdItemIds,
    };
  }
}

extension OwnerImports on OwnerAccess {
  List<ImportProposal> get importProposals =>
      _service._repository.importProposals;

  /// A trusted secure editor only. There is no Agent operation to supply or
  /// read this owner-entered value, and status contains metadata only.
  Future<void> fillImportCredential(
    String id,
    int version,
    String key,
    String secret,
  ) => fillImportCredentials(id, version, {key: secret});

  /// The trusted App stages all private edits in a single revision before the
  /// owner's whole-proposal save. Validation failure changes none of them.
  Future<void> fillImportCredentials(
    String id,
    int version,
    Map<String, String> values,
  ) => _serialize(() async {
    final revised = _filledImportCredentials(id, version, values);
    if (revised != null) await _service._repository.saveImportProposal(revised);
  });

  ImportProposal? _filledImportCredentials(
    String id,
    int version,
    Map<String, String> values,
  ) {
    final proposal = importProposals.where((p) => p.id == id).firstOrNull;
    if (proposal == null ||
        proposal.state != ImportProposalState.pending ||
        proposal.version != version) {
      throw const AccessFailure('proposal_changed');
    }
    if (values.isEmpty) return null;
    final revised = <String, ImportItemInput>{};
    for (final entry in values.entries) {
      final input = proposal.items.where((i) => i.key == entry.key).firstOrNull;
      if (input?.credential?.source != 'owner') {
        throw const AccessFailure('invalid_credential_input');
      }
      CredentialImportInput credential;
      try {
        credential = input!.credential!.withOwnerSecret(entry.value);
      } on FormatException {
        throw const AccessFailure('invalid_credential_content');
      }
      revised[entry.key] = ImportItemInput.fromPrivateJson({
        ...input.toJson(),
        'credential': credential.toPrivateJson(),
      });
    }
    return proposal.revise(
      items: [for (final old in proposal.items) revised[old.key] ?? old],
      approvedKeys: proposal.approvedKeys.where((k) => !values.containsKey(k)),
    );
  }

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
    return _approveImportCandidates(previous, reviewed);
  });

  Future<void> rejectImport(String id, int version) => _serialize(() async {
    final previous = _pendingImport(id, version);
    final rejected = previous.revise(
      items: const [],
      approvedKeys: const [],
      rejectedKeys: {
        ...previous.rejectedKeys,
        ...previous.items.map((i) => i.key),
      },
      state: previous.createdItemIds.isEmpty
          ? ImportProposalState.rejected
          : ImportProposalState.confirmed,
    );
    await _service._repository.commitInformationAdmission(
      [rejected],
      const [],
      decisionProposalId: id,
      confirm: false,
    );
  });
}
