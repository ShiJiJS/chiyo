part of 'info_core.dart';

class UpdateAdmissionStatus {
  const UpdateAdmissionStatus(this.state, [this.reason = '']);
  final String state, reason;
}

extension OwnerUpdateAdmission on OwnerAccess {
  ImportProposal _updateImportContext(UpdateProposal p) => ImportProposal(
    id: p.id,
    sessionBinding: p.sessionBinding,
    chatLabel: p.chatLabel,
    createdAt: p.createdAt,
    items: [p.input.compiledTemplate!.withKey('update')],
  );

  void _validatePendingUpdateTargets(UpdateProposal p) {
    if (p.input.pendingRelations.isEmpty) return;
    final context = _updateImportContext(p);
    _validatePendingImportTargets(context, context.items);
  }

  String? _updateAdmissionProblem(
    UpdateProposal p,
    Map<String, ImportProposal> imports,
  ) {
    if (p.input.templateId == null) return null;
    final context = _updateImportContext(p), input = context.items.single;
    final direct = _importDirectProblem((
      proposal: context,
      input: input,
    ), imports);
    if (direct != null) return direct;
    for (final ref in input.pendingRelations.values.expand((r) => r)) {
      final target = _importTarget(context, ref, imports);
      if (target != null &&
          importAdmission(
            target.proposal.id,
          ).any((s) => s.key == ref.itemKey && s.state == 'needs_attention')) {
        return '引用的「${target.proposal.candidateNames[ref.itemKey] ?? '资料'}」需要处理，请先核对其关联。';
      }
    }
    return null;
  }

  UpdateAdmissionStatus updateAdmission(String id) {
    final p = _update(id);
    if (p.state == UpdateProposalState.confirmed) {
      return const UpdateAdmissionStatus('admitted');
    }
    if (p.state == UpdateProposalState.rejected) {
      return const UpdateAdmissionStatus('rejected');
    }
    final original = information
        .where((i) => i.id == p.input.itemId)
        .firstOrNull;
    if (original == null || original.version != p.input.baseVersion) {
      return const UpdateAdmissionStatus(
        'needs_attention',
        '原资料已变化，请重新提交修改并审批；原内容未因此改变。',
      );
    }
    final imports = {for (final i in importProposals) i.id: i};
    final problem = _updateAdmissionProblem(p, imports);
    if (problem != null) {
      return UpdateAdmissionStatus('needs_attention', problem);
    }
    if (!p.approved) return const UpdateAdmissionStatus('pending');
    final names = [
      for (final ref in p.input.pendingRelations.values.expand((r) => r))
        if (imports[ref.proposalId]?.receiptFor(ref.itemKey) == null)
          imports[ref.proposalId]?.candidateNames[ref.itemKey] ?? '关联资料',
    ];
    return UpdateAdmissionStatus(
      'approved',
      names.isEmpty
          ? '已批准，等待关联资料一起保存；原内容尚未改变。'
          : '已批准，等待「${names.toSet().join('、')}」获准后保存修改；原内容尚未改变。',
    );
  }

  UpdateInput _resolvedUpdateInput(
    UpdateInput input,
    Map<String, List<InformationRelationRef>> relations,
  ) => _compileTemplateUpdate(
    UpdateInput(
      input.itemId,
      input.baseVersion,
      input.changes,
      name: input.name,
      description: input.description,
      templateId: input.templateId,
      templateVersion: input.templateVersion,
      templateDigest: input.templateDigest,
      values: input.values,
      relations: relations,
      compiledTemplate: input.compiledTemplate,
      attachments: input.attachments,
      filePlan: input.filePlan,
    ),
  );

  List<InformationUpdateAdmission> _prepareApprovedUpdates({
    UpdateProposal? rootUpdate,
    required Map<String, ImportProposal> imports,
    required Map<String, String> identities,
  }) {
    final proposals = [
      ?rootUpdate,
      ...updateProposals.where((p) => p.id != rootUpdate?.id),
    ];
    final commits = <InformationUpdateAdmission>[];
    final changedTargets = <String>{};
    for (final p in proposals.where(
      (p) => p.state == UpdateProposalState.pending && p.approved,
    )) {
      InformationUpdateAdmission? prepared;
      try {
        if (!changedTargets.contains(p.input.itemId) &&
            _updateAdmissionProblem(p, imports) == null) {
          final relations = {
            for (final e
                in p.input.relations?.entries ??
                    <MapEntry<String, List<InformationRelationRef>>>[])
              e.key: e.value.toList(),
          };
          var available = true;
          if (p.input.pendingRelations.isNotEmpty) {
            final context = _updateImportContext(p);
            for (final e in p.input.pendingRelations.entries) {
              for (final ref in e.value) {
                final target = _importTarget(context, ref, imports);
                final id =
                    target?.receipt?.id ??
                    identities[_importNodeKey(
                      ref.proposalId ?? p.id,
                      ref.itemKey,
                    )];
                if (id == null) {
                  available = false;
                  continue;
                }
                (relations[e.key] ??= []).add(
                  InformationRelationRef(ref.kind, id),
                );
              }
            }
          }
          if (available) {
            final reviewed = p.approvedReview!;
            final input =
                p.input.templateId == null || p.input.relations == null
                ? p.input
                : _resolvedUpdateInput(p.input, {
                    for (final e in relations.entries)
                      e.key: e.value.toSet().toList(),
                  });
            final preview = previewUpdate(
              p.id,
              review: UpdateReview(
                input,
                directoryId: reviewed.directoryId,
                tagIds: reviewed.tagIds,
                fieldDescriptions: reviewed.fieldDescriptions,
              ),
            );
            final after = preview.after;
            final removed = preview.before.fields.any(
              (f) => !after.fields.any((n) => n.id == f.id),
            );
            final recycled = removed ? _recycle(preview.before, after) : null;
            prepared = InformationUpdateAdmission(
              p.finish(
                UpdateProposalState.confirmed,
                result: UpdateReceipt(after.id, after.version),
                resultingVersion: p.id == rootUpdate?.id
                    ? rootUpdate!.version
                    : p.version + 1,
              ),
              item: after,
              filePromotions: p.input.filePlan?.promotions ?? const [],
              previous: InformationRevision(preview.before, _service._clock()),
              recycled: recycled == null ? const [] : [recycled],
              facts: recycled == null
                  ? const []
                  : [_fact(recycled, RecycleFactKind.deleted, after.version)],
            );
            changedTargets.add(after.id);
          }
        }
      } on AccessFailure catch (error) {
        // A waiting approval never overwrites a later owner edit or adopts a
        // changed plugin. Keep its private review for explicit repair instead.
        if (p.id == rootUpdate?.id &&
            !{
              'proposal_conflict',
              'template_missing',
              'template_changed',
              'template_unavailable',
              'proposal_reference_unavailable',
            }.contains(error.status)) {
          rethrow;
        }
      }
      if (prepared != null) {
        commits.add(prepared);
      } else if (p.id == rootUpdate?.id) {
        commits.add(InformationUpdateAdmission(p));
      }
    }
    return commits;
  }
}
