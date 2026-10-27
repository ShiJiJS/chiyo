part of 'sample_workspace_source.dart';

extension _OrganizationProposals on _SampleProposals {
  List<WorkspaceGrantEvent> organizationEvents(String request) => [
    for (final r in _rows.values)
      if (r.organization?.requestId == request)
        WorkspaceGrantEvent(
          r.organization!.operationId!,
          r.organization!.at,
          '在固定范围内整理目录与标签',
          r.organization!.outcome.label,
          proposalId: r.id,
        ),
  ];
  WorkspaceOrganizationLocation _location(WorkspaceDetail d) =>
      WorkspaceOrganizationLocation(
        directoryId: d.record.directoryId,
        directoryName:
            s._catalog.directories
                .where((x) => x.id == d.record.directoryId)
                .firstOrNull
                ?.name ??
            '未分类',
        tags: d.record.tags,
      );

  List<WorkspaceOrganizationMember> _members(
    Iterable<WorkspaceRecordRef> refs,
  ) {
    final records = refs
        .map((r) => s._records[r])
        .whereType<WorkspaceDetail>()
        .toList();
    return [
      for (final (index, d) in records.indexed)
        WorkspaceOrganizationMember(
          record: d.record.ref,
          name: d.record.name,
          baseVersion: d.version,
          before: _location(d),
          after: index == records.length - 1
              ? _location(d)
              : WorkspaceOrganizationLocation(
                  directoryId: 'selfhost',
                  directoryName: '自托管服务',
                  tags: {
                    ...{for (final t in d.record.tags) t.id: t},
                    for (final t in s._catalog.tags.where(
                      (t) => t.name == '生产环境' || t.name == '公网入口',
                    ))
                      t.id: t,
                  }.values,
                ),
        ),
    ];
  }

  /// All versions, classification and storage are checked before any mutation.
  /// Only the original metadata plan is accepted; content and identities stay.
  List<_ProposalSaved> _applyOrganization(WorkspaceOrganizationReport report) {
    if (report.members.isEmpty ||
        report.members.length > 200 ||
        report.members.map((m) => m.record).toSet().length !=
            report.members.length) {
      throw const WorkspaceFailure('validation', '整理范围无效。');
    }
    final prepared = <WorkspaceDetail>[];
    for (final m in report.members) {
      final raw = s._records[m.record];
      final old = raw == null ? null : s._projectRecord(raw);
      if (m.record.kind != WorkspaceRecordKind.information ||
          old == null ||
          old.version != m.baseVersion) {
        throw const WorkspaceFailure('conflict', '范围中的资料版本已变化，整批没有应用。');
      }
      if (m.after.directoryId != null &&
              !s._catalog.directories.any(
                (d) =>
                    d.id == m.after.directoryId &&
                    !['all', 'unfiled'].contains(d.id),
              ) ||
          m.after.tags.length > 100 ||
          m.after.tags.map((t) => t.id).toSet().length != m.after.tags.length ||
          m.after.tags.any((t) => !s._catalog.tags.any((x) => x.id == t.id))) {
        throw const WorkspaceFailure('conflict', '目录或标签已变化，整批没有应用。');
      }
      prepared.add(
        WorkspaceDetail(
          record: WorkspaceRecordSummary(
            ref: old.record.ref,
            name: old.record.name,
            description: old.record.description,
            type: old.record.type,
            updatedAt: s._now(),
            directoryId: m.after.directoryId,
            tags: m.after.tags,
          ),
          version: old.version + 1,
          definition: old.definition,
          values: old.values,
          relations: old.relations,
          fieldIds: old.fieldIds,
          fieldOverrides: old.fieldOverrides,
          retainedFields: old.retainedFields,
          retainedRelations: old.retainedRelations,
        ),
      );
    }
    if (s.nextSaveFailure case final failure?) {
      s.nextSaveFailure = null;
      throw failure;
    }
    // No await from this point through the caller's terminal report/receipt.
    for (final d in prepared) {
      (s._revisions[d.record.ref] ??= []).add(
        s._archive(s._projectRecord(s._records[d.record.ref]!)),
      );
      s._putRecord(d);
    }
    return [
      for (final d in prepared)
        _ProposalSaved(
          WorkspaceRecordReceipt(ref: d.record.ref, version: d.version),
          d.record.name,
        ),
    ];
  }

  Future<void> _demonstrateOrganization(
    WorkspaceOrganizationOutcome requested,
  ) async {
    final epoch = s._epoch, generation = _generation;
    void alive() {
      if (s._disposed || epoch != s._epoch || generation != _generation) {
        throw const WorkspaceFailure('cancelled', '资料集已变化，原整理不会继续。');
      }
    }

    if ([
      WorkspaceOrganizationOutcome.proposed,
      WorkspaceOrganizationOutcome.rejected,
    ].contains(requested)) {
      throw const WorkspaceFailure('validation', '新整理结果不使用旧版确认状态。');
    }
    await s._readable();
    alive();
    _seed();
    const id = 'organized', request = 'organize';
    if (_rows.containsKey(id)) return;
    final approval = await s.approvals.read(request);
    alive();
    if (approval.request.state == WorkspaceApprovalState.pending) {
      await s.approvals.change(
        WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: request,
          reviewToken: approval.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: approval.scopes.where((x) => x.available).map((x) => x.id),
          fieldMinutes: 30,
        ),
      );
      alive();
    }
    final input = s._approvals._all().singleWhere((r) => r.id == request),
        fact = s._approvals._facts[request];
    if (fact == null || fact.action != WorkspaceApprovalAction.approve) {
      throw const WorkspaceFailure('unavailable', '原整理申请未获批准。');
    }
    final report = WorkspaceOrganizationReport(
      outcome: WorkspaceOrganizationOutcome.applied,
      members: _members(fact.scopes.values.map((x) => x.record)),
      at: s._approvals.now,
      approvedAt: fact.at,
      expiresAt: fact.fieldEnd,
      requestId: request,
      historyId: 'request:$request',
      operationId: workspaceOperationId(),
    );
    if (requested == WorkspaceOrganizationOutcome.revoked) {
      final current = await s.approvals.read(request);
      alive();
      await s.approvals.change(
        WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: request,
          reviewToken: current.reviewToken,
          action: WorkspaceApprovalAction.revoke,
        ),
      );
      alive();
    } else if (requested == WorkspaceOrganizationOutcome.expired) {
      s._approvals.advance(const Duration(hours: 1));
    } else if (requested == WorkspaceOrganizationOutcome.sessionEnded) {
      s._approvals.endSession(input.session.id);
    } else if (requested == WorkspaceOrganizationOutcome.conflicted) {
      final old = s._records[report.members.first.record]!;
      await s.saveRecord(
        WorkspaceEdit(
          operationId: workspaceOperationId(),
          record: old.record,
          expectedVersion: old.version,
          values: {...old.values, 'purpose': '主人已更新用途'},
        ),
      );
      alive();
    } else if (requested == WorkspaceOrganizationOutcome.failed) {
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '保存失败，整批没有应用。');
    }
    var outcome = requested;
    String? reason;
    var saved = <_ProposalSaved>[];
    final state = s._approvals._state(input);
    if (state != WorkspaceApprovalState.approved) {
      outcome = switch (state) {
        WorkspaceApprovalState.revoked => WorkspaceOrganizationOutcome.revoked,
        WorkspaceApprovalState.expired => WorkspaceOrganizationOutcome.expired,
        WorkspaceApprovalState.sessionEnded =>
          WorkspaceOrganizationOutcome.sessionEnded,
        _ => WorkspaceOrganizationOutcome.conflicted,
      };
      reason = '原整理能力已结束，未再读取或写入资料。';
    } else {
      try {
        // Check every approved member, including those not changing metadata.
        if (report.members.length != fact.scopes.length ||
            report.members.any(
              (m) => !fact.scopes.values.any(
                (x) => x.record == m.record && x.recordVersion == m.baseVersion,
              ),
            )) {
          throw const WorkspaceFailure('conflict', '批准时的固定资料版本已变化，整批没有应用。');
        }
        saved = _applyOrganization(report);
        outcome = WorkspaceOrganizationOutcome.applied;
        s._approvals._organizationFinished.add(request);
      } on WorkspaceFailure catch (error) {
        outcome = error.code == 'conflict'
            ? WorkspaceOrganizationOutcome.conflicted
            : WorkspaceOrganizationOutcome.failed;
        reason = error.message;
        if (outcome == WorkspaceOrganizationOutcome.conflicted) {
          s._approvals._organizationFinished.add(request);
        }
      }
    }
    final actual = WorkspaceOrganizationReport(
      outcome: outcome,
      members: report.members.map(
        (m) => m.project(
          version: saved
              .where((x) => x.receipt.ref == m.record)
              .firstOrNull
              ?.receipt
              .version,
        ),
      ),
      at: s._approvals.now,
      requestId: report.requestId,
      historyId: report.historyId,
      operationId: report.operationId,
      approvedAt: report.approvedAt,
      expiresAt: report.expiresAt,
      reason: reason,
    );
    if (requested == WorkspaceOrganizationOutcome.unknown &&
        outcome == WorkspaceOrganizationOutcome.applied) {
      _organizationUnobserved[id] = actual;
    }
    final row =
        _ProposalInput(
            id,
            '整理自托管服务资料',
            WorkspaceProposalKind.organization,
            input.purpose,
            actual.at,
            [],
            organization: _organizationUnobserved.containsKey(id)
                ? actual.project(outcome: WorkspaceOrganizationOutcome.unknown)
                : actual,
          )
          ..status =
              outcome == WorkspaceOrganizationOutcome.applied &&
                  requested != WorkspaceOrganizationOutcome.unknown
              ? WorkspaceProposalStatus.completed
              : WorkspaceProposalStatus.ended
          ..itemCount = actual.members.length;
    _rows[id] = row;
    s._changes.add(null);
  }

  void demonstrateLegacyOrganization() {
    _seed();
    const id = 'legacy-organize';
    if (_rows.containsKey(id)) return;
    final report = WorkspaceOrganizationReport(
      outcome: WorkspaceOrganizationOutcome.proposed,
      legacyReview: true,
      members: _members(['blinko', 'vikunja', 'sparky'].map(info)),
      at: s._now(),
    );
    final items = [
      for (final m in report.members)
        WorkspaceProposalItem(
          id: m.record.key,
          before: WorkspaceDetail(
            record: s._records[m.record]!.record,
            version: m.baseVersion,
            definition: const {},
          ),
          proposed: WorkspaceDetail(
            record: WorkspaceRecordSummary(
              ref: m.record,
              name: m.name,
              description: s._records[m.record]!.record.description,
              type: s._records[m.record]!.record.type,
              updatedAt: report.at,
              directoryId: m.after.directoryId,
              tags: m.after.tags,
            ),
            version: m.baseVersion,
            definition: const {},
          ),
        ),
    ];
    _rows[id] = _ProposalInput(
      id,
      '旧版待确认：整理服务分类',
      WorkspaceProposalKind.organization,
      '此方案沿用旧版再次审阅语义，尚未应用目录和标签。',
      report.at,
      items,
      organization: report,
    );
    s._changes.add(null);
  }

  WorkspaceProposalReceipt _changeLegacyOrganization(
    _ProposalInput r,
    WorkspaceProposalChange c,
  ) {
    final org = r.organization;
    if (org == null ||
        !org.legacyReview ||
        org.outcome != WorkspaceOrganizationOutcome.proposed) {
      throw const WorkspaceFailure('unsupported', '整理结果只读，不提供第二次批准。');
    }
    var saved = <_ProposalSaved>[];
    if (c.action == WorkspaceProposalAction.confirm) {
      if (c.reviewed.length != r.items.length ||
          c.reviewed.map((x) => x.itemId).toSet().length != r.items.length ||
          c.reviewed.any(
            (review) => !r.items.any(
              (item) =>
                  item.id == review.itemId &&
                  _same(
                    WorkspaceProposalItemReview.fromItem(item).toJson(),
                    review.toJson(),
                  ),
            ),
          )) {
        throw const WorkspaceFailure(
          'validation',
          '旧版方案只能确认原有整批分类建议，不能夹带正文、名称或其他范围。',
        );
      }
      saved = _applyOrganization(org);
    } else if (s.nextSaveFailure case final failure?) {
      s.nextSaveFailure = null;
      throw failure;
    }
    r.status = c.action == WorkspaceProposalAction.confirm
        ? WorkspaceProposalStatus.completed
        : WorkspaceProposalStatus.rejected;
    r.version++;
    r.saved = List.unmodifiable(saved);
    r.items = const [];
    r.organization = org.project(
      outcome: c.action == WorkspaceProposalAction.confirm
          ? WorkspaceOrganizationOutcome.applied
          : WorkspaceOrganizationOutcome.rejected,
      operationId: c.operationId,
      members: org.members.map(
        (m) => m.project(
          version: saved
              .where((x) => x.receipt.ref == m.record)
              .firstOrNull
              ?.receipt
              .version,
        ),
      ),
    );
    final receipt = WorkspaceProposalReceipt(
      operationId: c.operationId,
      proposalId: c.proposalId,
      action: c.action,
      reviewToken: c.reviewToken,
      reviewedVersion: c.version,
      resultingVersion: r.version,
      commandDigest: c.digest,
      records: saved.map((x) => x.receipt),
    );
    _receipts[c.operationId] = receipt;
    s._changes.add(null);
    if (loseNextReply || loseReplyFor == c.proposalId) {
      loseNextReply = false;
      loseReplyFor = null;
      throw const WorkspaceFailure('unknown_outcome', '决定结果未知，请查询原操作。');
    }
    return receipt;
  }
}
