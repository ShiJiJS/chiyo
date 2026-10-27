part of 'sample_workspace_source.dart';

/// Read-only projection of existing decisions and retained credential audit.
/// It owns no independently mutable grants, deadlines or operation outcomes.
class _SampleGrantHistory implements WorkspaceGrantHistorySource {
  _SampleGrantHistory(this.s);
  final SampleWorkspaceSource s;
  String currentId(String request) => 'request:$request';
  String legacyId(WorkspaceRecordRef ref, String grant) =>
      'legacy:${ref.key}:$grant';
  List<_ApprovalInput> get decided => s._approvals
      ._all()
      .where((r) => s._approvals._facts.containsKey(r.id))
      .toList();
  WorkspaceGrantState state(_ApprovalInput r) {
    final a = s._approvals, f = a._facts[r.id]!;
    return switch (a._state(r)) {
      WorkspaceApprovalState.approved =>
        a._scopes(r).where((x) => a._active(r, x, f)).length < f.scopes.length
            ? WorkspaceGrantState.partial
            : WorkspaceGrantState.active,
      WorkspaceApprovalState.denied => WorkspaceGrantState.denied,
      WorkspaceApprovalState.revoked => WorkspaceGrantState.revoked,
      WorkspaceApprovalState.expired => WorkspaceGrantState.expired,
      WorkspaceApprovalState.sessionEnded => WorkspaceGrantState.sessionEnded,
      WorkspaceApprovalState.completed => WorkspaceGrantState.completed,
      _ => WorkspaceGrantState.unavailable,
    };
  }

  WorkspaceGrantSummary summary(_ApprovalInput r) {
    final a = s._approvals, f = a._facts[r.id]!, scopes = f.scopes.values;
    final kind = f.action == WorkspaceApprovalAction.deny
        ? r.kind
        : r.kind == WorkspaceApprovalKind.organization
        ? r.kind
        : scopes.any((x) => x.kind == WorkspaceApprovalScopeKind.credential)
        ? r.kind
        : scopes.any((x) => x.kind == WorkspaceApprovalScopeKind.file)
        ? WorkspaceApprovalKind.file
        : WorkspaceApprovalKind.information;
    return WorkspaceGrantSummary(
      id: currentId(r.id),
      requestId: r.id,
      title: r.title,
      kind: kind,
      state: state(r),
      agentClaim: r.session.agentClaim,
      chatClaim: r.session.label,
      purpose: r.purpose,
      recordedAt: f.at,
      operationCount:
          (a._executions[r.id]?.length ?? 0) +
          s._proposals.organizationEvents(r.id).length,
    );
  }

  WorkspaceGrantSummary legacySummary(
    WorkspaceRecordRef ref,
    WorkspaceCredentialUseHistory h,
  ) => WorkspaceGrantSummary(
    id: legacyId(ref, h.grantId),
    title: h.credentialName,
    kind: WorkspaceApprovalKind.credential,
    state: WorkspaceGrantState.expired,
    agentClaim: h.session.agentClaim,
    chatClaim: h.session.label,
    purpose: h.purpose,
    recordedAt: h.operations.isEmpty ? h.expiresAt : h.operations.last.at,
    operationCount: h.operations.length,
  );
  List<WorkspaceGrantSummary> get all =>
      s._scenario == SampleWorkspaceScenario.empty
      ? []
      : [
          for (final r in decided) summary(r),
          for (final e in s._credentials.retainedHistory.entries)
            for (final h in e.value) legacySummary(e.key, h),
        ];
  @override
  Future<WorkspaceGrantResults> query(
    WorkspaceGrantQuery q, {
    String? keepSelection,
  }) async {
    await s._readable();
    if (q.keyword.length > 1000 ||
        q.offset < 0 ||
        q.offset > 1000000 ||
        q.limit < 1 ||
        q.limit > 100 ||
        q.lastDays != null && ![1, 7, 30].contains(q.lastDays)) {
      throw const WorkspaceFailure('invalid_query', '请核对历史查询条件。');
    }
    final cutoff = q.lastDays == null
        ? null
        : s._approvals.now.subtract(Duration(days: q.lastDays!));
    final rows =
        all
            .where(
              (h) =>
                  (q.filter == WorkspaceGrantFilter.all ||
                      (q.filter == WorkspaceGrantFilter.active) ==
                          h.state.isActive) &&
                  (q.kind == null || h.kind == q.kind) &&
                  (cutoff == null || !h.recordedAt.isBefore(cutoff)) &&
                  '${h.title} ${h.purpose} ${h.agentClaim} ${h.chatClaim} ${h.kind.label}'
                      .toLowerCase()
                      .contains(q.keyword.trim().toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final t = b.recordedAt.compareTo(a.recordedAt);
            return t != 0 ? t : a.id.compareTo(b.id);
          });
    final offset = rows.isEmpty
        ? 0
        : q.offset.clamp(0, (rows.length - 1) ~/ q.limit * q.limit);
    final selection = rows.any((x) => x.id == keepSelection)
        ? keepSelection
        : rows.skip(offset).firstOrNull?.id;
    return WorkspaceGrantResults(
      items: rows.skip(offset).take(q.limit),
      total: rows.length,
      offset: offset,
      selection: selection,
      selectionIndex: selection == null
          ? null
          : rows.indexWhere((x) => x.id == selection),
    );
  }

  WorkspaceArchive? archive(WorkspaceRecordRef ref, int version) {
    if (ref.kind != WorkspaceRecordKind.information ||
        s._scenario == SampleWorkspaceScenario.empty) {
      return null;
    }
    final current = s._records[ref];
    if (current?.version == version) return s._archive(current!);
    for (final a in s._revisions[ref] ?? <WorkspaceArchive>[]) {
      if (a.detail.version == version) return a;
    }
    for (final r in s._recycled.values) {
      if (r.entry.wholeItem &&
          r.archive.detail.record.ref == ref &&
          r.archive.detail.version == version) {
        return r.archive;
      }
    }
    return null;
  }

  @override
  Future<WorkspaceGrantDetail> read(String id) async {
    await s._readable();
    if (s._scenario == SampleWorkspaceScenario.empty) {
      throw const WorkspaceFailure('not_found', '原授权记录已不可用。');
    }
    final a = s._approvals,
        r = decided.where((r) => currentId(r.id) == id).firstOrNull;
    if (r != null) {
      final f = a._facts[r.id]!, live = {for (final x in a._scopes(r)) x.id: x};
      final scopes = [
        for (final x in f.scopes.values)
          WorkspaceGrantedScope(
            id: x.id,
            record: x.record,
            label: x.label,
            recordVersion: x.recordVersion,
            kind: x.kind,
            active: live[x.id] != null && a._active(r, live[x.id]!, f),
            expiresAt: x.kind == WorkspaceApprovalScopeKind.credential
                ? f.credentialEnd
                : f.fieldEnd,
            fileVersion: f.files[x.id],
            materialVersion: x.kind == WorkspaceApprovalScopeKind.credential
                ? r.credential?.materialVersion
                : null,
          ),
      ];
      return WorkspaceGrantDetail(
        summary: summary(r),
        scopes: scopes,
        targets: [
          for (final ref in f.scopes.values.map((x) => x.record).toSet())
            WorkspaceGrantTarget(
              record: ref,
              name: f.scopes.values
                  .firstWhere((x) => x.record == ref)
                  .recordName,
              version: f.scopes.values
                  .firstWhere((x) => x.record == ref)
                  .recordVersion,
              exists: s._records.containsKey(ref),
              snapshotAvailable:
                  archive(
                    ref,
                    f.scopes.values
                        .firstWhere((x) => x.record == ref)
                        .recordVersion,
                  ) !=
                  null,
            ),
        ],
        reviewToken: a._stamp(r),
        events: s._proposals.organizationEvents(r.id),
        decidedAt: f.at,
        fieldExpiresAt: f.fieldEnd,
        credentialExpiresAt: f.credentialEnd,
        legacyNotice: a._restored.contains(r.id)
            ? '来自备份的历史事实；授权与原设备进程、临时材料不在本机重新生效。'
            : null,
      );
    }
    for (final e in s._credentials.retainedHistory.entries) {
      for (final h in e.value) {
        if (legacyId(e.key, h.grantId) != id) continue;
        return WorkspaceGrantDetail(
          summary: legacySummary(e.key, h),
          scopes: [
            WorkspaceGrantedScope(
              id: h.grantId,
              record: e.key,
              label: '${h.credentialName} · 材料v${h.materialVersion}',
              recordVersion: 0,
              kind: WorkspaceApprovalScopeKind.credential,
              active: false,
              expiresAt: h.expiresAt,
              materialVersion: h.materialVersion,
            ),
          ],
          targets: [
            WorkspaceGrantTarget(
              record: e.key,
              name: h.credentialName,
              version: 0,
              exists: s._records.containsKey(e.key),
              snapshotAvailable: false,
            ),
          ],
          events: [
            for (final o in h.operations)
              WorkspaceGrantEvent(o.id, o.at, o.description, o.result),
          ],
          credentialExpiresAt: h.expiresAt,
          legacyNotice: '这条旧记录仅保留批准和使用结果摘要，没有可查询的原操作计划。',
        );
      }
    }
    throw const WorkspaceFailure('not_found', '原授权记录已不可用。');
  }

  @override
  Future<WorkspaceFilePreview> filePreview(
    String historyId,
    String scopeId, {
    int page = 0,
  }) async {
    final epoch = s._epoch;
    final d = await read(historyId);
    final request = decided
        .where((r) => currentId(r.id) == d.summary.id)
        .firstOrNull;
    final scope = request == null
        ? null
        : s._approvals._facts[request.id]?.scopes[scopeId];
    final version = request == null
        ? null
        : s._approvals._facts[request.id]?.files[scopeId];
    final expected = scope?.fileVersions
        .where((v) => v.ref.version == version)
        .firstOrNull;
    if (scope == null ||
        scope.kind != WorkspaceApprovalScopeKind.file ||
        version == null ||
        expected == null) {
      throw const WorkspaceFailure('history_unavailable', '批准的附件版本已不可用。');
    }
    WorkspaceDetail? record = s._records[scope.record];
    var key = record?.fieldIds.entries
        .where((e) => e.value == scope.fieldId)
        .firstOrNull
        ?.key;
    if (key == null) {
      record = archive(scope.record, scope.recordVersion)?.detail;
      key = scope.fieldKey;
    }
    if (record == null ||
        key == null ||
        !s._files.retainsVersion(record, key, version)) {
      throw const WorkspaceFailure(
        'history_unavailable',
        '批准的附件版本已不可用，不会替换成当前版本。',
      );
    }
    final result = await s._files.preview(
      record,
      key,
      version: version,
      page: page,
    );
    if (epoch != s._epoch ||
        s._disposed ||
        !s._files.retainsVersion(record, key, version) ||
        result.file.ref != expected.ref) {
      throw const WorkspaceFailure('cancelled', '附件或历史状态已变化，请重新读取。');
    }
    return result;
  }

  @override
  Future<WorkspaceArchive> snapshot(
    String historyId,
    WorkspaceRecordRef record,
  ) async {
    final epoch = s._epoch;
    final d = await read(historyId);
    if (epoch != s._epoch || s._disposed) {
      throw const WorkspaceFailure('cancelled', '历史状态已变化，请重新读取。');
    }
    final target = d.targets.where((x) => x.record == record).firstOrNull;
    if (record.kind != WorkspaceRecordKind.information || target == null) {
      throw const WorkspaceFailure('unsupported', '这里只能查看普通信息的准确历史版本，不提供凭据秘密。');
    }
    return archive(record, target.version) ??
        (throw const WorkspaceFailure(
          'history_unavailable',
          '批准时的资料快照已不可用，不会替换为当前或同名内容。',
        ));
  }
}
