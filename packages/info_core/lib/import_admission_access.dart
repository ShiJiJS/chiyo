part of 'info_core.dart';

typedef _ImportNode = ({ImportProposal proposal, ImportItemInput input});
String _importNodeKey(String proposal, String item) => '$proposal/$item';

class ImportCandidateStatus {
  const ImportCandidateStatus(this.key, this.state, {this.reason = ''});
  final String key, state, reason;
}

extension OwnerImportAdmission on OwnerAccess {
  Map<String, _ImportNode> _importNodes(Iterable<ImportProposal> proposals) => {
    for (final p in proposals.where(
      (p) => p.state == ImportProposalState.pending,
    ))
      for (final input in p.items)
        _importNodeKey(p.id, input.key): (proposal: p, input: input),
  };

  /// Only owner-reviewed definitions and submitted values participate. No
  /// placeholder information record or grant is created while approval waits.
  bool _importTemplateCurrent(ImportItemInput input) {
    if (input.templateId == null) return true;
    try {
      final t = _service.agent
          ._currentInformationTemplates()
          .templates
          .where((t) => t.id == input.templateId)
          .firstOrNull;
      return t != null &&
          t.enabled &&
          t.version == input.templateVersion &&
          t.digest == input.templateDigest;
    } on AccessFailure {
      return false;
    }
  }

  ({ImportProposal proposal, ImportItemInput? input, ImportReceipt? receipt})?
  _importTarget(
    ImportProposal from,
    ImportPendingReference ref,
    Map<String, ImportProposal> proposals,
  ) {
    if (ref.kind != 'information') {
      return null; // Credential candidates join in #79.
    }
    final p = proposals[ref.proposalId ?? from.id];
    if (p == null || p.sessionBinding != from.sessionBinding) return null;
    final receipt = p.receiptFor(ref.itemKey);
    final input = p.items.where((i) => i.key == ref.itemKey).firstOrNull;
    if (receipt == null && input == null) return null;
    return (proposal: p, input: input, receipt: receipt);
  }

  bool _importTargetType(ImportItemInput input, String relation, String? type) {
    final definition = input.layout?.snapshot['definition'] as Map?;
    final descriptor = (definition?['relations'] as List? ?? [])
        .cast<Map>()
        .where((r) => r['key'] == relation)
        .firstOrNull;
    if (descriptor == null) return false;
    final allowed = (descriptor['targetTemplates'] as List? ?? [])
        .cast<String>();
    return allowed.isEmpty || allowed.contains(type ?? 'generic');
  }

  String? _importDirectProblem(
    _ImportNode node,
    Map<String, ImportProposal> proposals,
  ) {
    if (!_importTemplateCurrent(node.input)) return '所用模板已变化，请核对后重新审批。';
    try {
      _validateImportedRelations(node.input);
    } on AccessFailure {
      return '关联目标已不可用或不符合模板，请修改后重新审批。';
    }
    for (final e in node.input.pendingRelations.entries) {
      for (final ref in e.value) {
        final p = proposals[ref.proposalId ?? node.proposal.id];
        if (p?.rejectedKeys.contains(ref.itemKey) == true ||
            p?.state == ImportProposalState.rejected) {
          return '引用的「${p!.candidateNames[ref.itemKey] ?? '待录入资料'}」已被拒绝，请更改关联后重新审批。';
        }
        final target = _importTarget(node.proposal, ref, proposals);
        if (target == null) return '引用的待录入资料已不可用，请更改关联后重新审批。';
        final saved = target.receipt == null
            ? null
            : information.where((i) => i.id == target.receipt!.id).firstOrNull;
        if (target.receipt != null && saved == null) {
          return '引用的资料已移除，请更改关联后重新审批。';
        }
        if (!_importTargetType(
          node.input,
          e.key,
          saved?.layout?.typeId ?? target.input?.templateId,
        )) {
          return '引用的资料类型不符合模板，请更改关联后重新审批。';
        }
      }
    }
    return null;
  }

  List<ImportCandidateStatus> importAdmission(String id) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final proposals = {for (final p in importProposals) p.id: p};
    final p = proposals[id];
    if (p == null) throw const AccessFailure('proposal_changed');
    final nodes = _importNodes(proposals.values);
    String? problem(_ImportNode node, Set<String> path) {
      final key = _importNodeKey(node.proposal.id, node.input.key);
      if (!path.add(key)) return null;
      final direct = _importDirectProblem(node, proposals);
      if (direct != null) return direct;
      for (final ref in node.input.pendingRelations.values.expand((r) => r)) {
        final target =
            nodes[_importNodeKey(
              ref.proposalId ?? node.proposal.id,
              ref.itemKey,
            )];
        if (target != null && problem(target, {...path}) != null) {
          return '引用的「${target.input.name}」需要处理，请先核对其关联或模板。';
        }
      }
      return null;
    }

    return [
      for (final key in p.candidateNames.keys)
        if (p.receiptFor(key) != null)
          ImportCandidateStatus(key, 'admitted')
        else if (p.rejectedKeys.contains(key) ||
            p.state == ImportProposalState.rejected)
          ImportCandidateStatus(key, 'rejected')
        else if (nodes[_importNodeKey(id, key)] case final node?)
          (() {
            final reason = problem(node, {});
            if (reason != null) {
              return ImportCandidateStatus(
                key,
                'needs_attention',
                reason: reason,
              );
            }
            if (!p.approvedKeys.contains(key)) {
              return ImportCandidateStatus(key, 'pending');
            }
            final names = [
              for (final ref in node.input.pendingRelations.values.expand(
                (r) => r,
              ))
                if (_importTarget(p, ref, proposals)?.receipt == null)
                  proposals[ref.proposalId ?? id]?.candidateNames[ref
                          .itemKey] ??
                      '关联资料',
            ];
            return ImportCandidateStatus(
              key,
              'approved',
              reason: names.isEmpty
                  ? '已批准，等待关联资料一起入库。'
                  : '已批准，等待「${names.toSet().join('、')}」获准后一起入库。',
            );
          })(),
    ];
  }

  void _validatePendingImportTargets(
    ImportProposal p,
    List<ImportItemInput> items,
  ) {
    final proposals = {for (final old in importProposals) old.id: old, p.id: p};
    for (final item in items) {
      for (final ref in item.pendingRelations.values.expand((r) => r)) {
        if (_importTarget(p, ref, proposals) == null) {
          throw const AccessFailure('invalid_reference');
        }
      }
    }
  }

  Future<List<ImportReceipt>> _approveImportCandidates(
    ImportProposal previous,
    List<ImportItemInput> reviewed,
  ) async {
    // The key stays stable after partial admission; indices are presentation only.
    reviewed = [
      for (final (index, r) in reviewed.indexed)
        r.key.isEmpty
            ? r.withKey(
                index < previous.items.length ? previous.items[index].key : '',
              )
            : r,
    ];
    if (reviewed.map((i) => i.key).toSet().length != reviewed.length ||
        reviewed.any((i) => !previous.items.any((old) => old.key == i.key))) {
      throw const AccessFailure('proposal_changed');
    }
    reviewed = _compileTemplateImports(reviewed);
    _validateImport(reviewed);
    for (final input in reviewed) {
      _validateImportedRelations(input);
    }
    final byKey = {for (final r in reviewed) r.key: r};
    final root = previous.revise(
      items: [for (final i in previous.items) byKey[i.key] ?? i],
      approvedKeys: {...previous.approvedKeys, ...byKey.keys},
    );
    _validatePendingImportTargets(root, reviewed);
    return _settleApprovedAdmissions(
      rootImport: root,
      selectedKeys: byKey.keys.toSet(),
    );
  }

  Future<List<ImportReceipt>> _settleApprovedAdmissions({
    ImportProposal? rootImport,
    UpdateProposal? rootUpdate,
    Set<String> selectedKeys = const {},
  }) async {
    final proposals = {for (final p in importProposals) p.id: p};
    if (rootImport != null) proposals[rootImport.id] = rootImport;
    final nodes = _importNodes(proposals.values);
    final eligible = {
      for (final e in nodes.entries)
        if (e.value.proposal.approvedKeys.contains(e.value.input.key) &&
            _importDirectProblem(e.value, proposals) == null)
          e.key,
    };
    // Greatest fixed point keeps a fully approved cycle together. Any edge to
    // an unapproved/invalid target removes its dependent, recursively.
    bool changed;
    do {
      final blocked = {
        for (final key in eligible)
          if (nodes[key]!.input.pendingRelations.values.expand((r) => r).any((
            ref,
          ) {
            final target = _importTarget(nodes[key]!.proposal, ref, proposals);
            return target == null ||
                target.receipt == null &&
                    !eligible.contains(
                      _importNodeKey(target.proposal.id, ref.itemKey),
                    );
          }))
            key,
      };
      changed = blocked.isNotEmpty;
      eligible.removeAll(blocked);
    } while (changed);
    final identities = {for (final key in eligible) key: _service._secret()};
    final items = <InformationItem>[];
    final organization = _OrganizationPlan(this);
    final now = _service._clock();
    for (final key in eligible) {
      final node = nodes[key]!, input = node.input;
      final fields = [
        for (final f in input.fields)
          InformationField(
            _service._secret(),
            f.name.trim(),
            f.description,
            f.value,
            1,
            kind: f.kind,
          ),
      ];
      final bound = input.bindLayout(fields);
      final relations = {
        for (final group in {
          ...input.relations.keys,
          ...input.pendingRelations.keys,
        })
          group: <InformationRelationRef>{
            ...input.relations[group] ?? [],
            for (final ref in input.pendingRelations[group] ?? [])
              (() {
                final target = _importTarget(node.proposal, ref, proposals)!;
                return InformationRelationRef(
                  ref.kind,
                  target.receipt?.id ??
                      identities[_importNodeKey(
                        target.proposal.id,
                        ref.itemKey,
                      )]!,
                );
              })(),
          }.toList(),
      };
      final location = organization.resolve(
        input.directoryId,
        input.tagIds,
        input.suggestedDirectory,
        input.suggestedTags,
      );
      items.add(
        InformationItem(
          identities[key]!,
          input.name.trim(),
          input.description,
          1,
          fields,
          layout: bound == null
              ? null
              : InformationLayout(
                  typeId: bound.typeId,
                  snapshot: bound.snapshot,
                  fieldIds: bound.fieldIds,
                  relations: relations,
                ),
          directoryId: location.$1,
          tagIds: location.$2,
          createdAt: now,
          modifiedAt: now,
        ),
      );
    }
    final updates = <ImportProposal>[];
    for (final p in proposals.values) {
      final admitted = p.items
          .where((i) => eligible.contains(_importNodeKey(p.id, i.key)))
          .toList();
      if (p.id != rootImport?.id && admitted.isEmpty) continue;
      final remaining = p.items
          .where((i) => !eligible.contains(_importNodeKey(p.id, i.key)))
          .toList();
      updates.add(
        p.revise(
          items: remaining,
          approvedKeys: p.approvedKeys.where(
            (k) => remaining.any((i) => i.key == k),
          ),
          createdItemKeys: [
            ...p.createdItemKeys,
            ...admitted.map((i) => i.key),
          ],
          createdItemIds: [
            ...p.createdItemIds,
            for (final i in admitted) identities[_importNodeKey(p.id, i.key)]!,
          ],
          createdItemVersions: [
            ...p.createdItemVersions,
            for (final _ in admitted) 1,
          ],
          state: remaining.isEmpty
              ? ImportProposalState.confirmed
              : ImportProposalState.pending,
          version: p.id == rootImport?.id ? rootImport!.version : p.version + 1,
        ),
      );
    }
    final updateCommits = _prepareApprovedUpdates(
      rootUpdate: rootUpdate,
      imports: proposals,
      identities: identities,
    );
    final selectedReceipts = rootImport == null
        ? [
            for (final update in updateCommits)
              if (update.proposal.id == rootUpdate!.id && update.item != null)
                ImportReceipt(update.item!.id, update.item!.version),
          ]
        : [
            for (final key in selectedKeys)
              ?updates
                  .singleWhere((p) => p.id == rootImport.id)
                  .receiptFor(key),
          ];
    final awaiting = rootImport == null
        ? selectedReceipts.isEmpty
              ? [rootUpdate!.input.itemId]
              : <String>[]
        : selectedKeys
              .where(
                (k) =>
                    updates
                        .singleWhere((p) => p.id == rootImport.id)
                        .receiptFor(k) ==
                    null,
              )
              .toList();
    await _service._repository.commitInformationAdmission(
      updates,
      items,
      decisionProposalId: rootImport?.id ?? rootUpdate!.id,
      decisionKind: rootImport == null
          ? ProposalKind.modification
          : ProposalKind.addition,
      confirm: true,
      updates: updateCommits,
      decisionRecords: selectedReceipts,
      awaitingKeys: awaiting,
      newDirectories: organization.newDirectories,
      newTags: organization.newTags,
    );
    for (final update in updateCommits) {
      if (update.item != null) {
        _invalidateRemoved(update.previous!.item, update.item!);
      }
    }
    return selectedReceipts;
  }
}
