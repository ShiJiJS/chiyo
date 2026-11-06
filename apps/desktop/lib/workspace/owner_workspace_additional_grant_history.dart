part of 'owner_workspace_grant_history.dart';

/// Credential/organization audit metadata shares request identities with the
/// inbox. It never starts an operation, claims material, or substitutes content.
extension _AdditionalGrantHistory on OwnerWorkspaceGrantHistory {
  core.CredentialUseRequest? _credentialHistory(String id) => owner
      .credentialUseRequests
      .where((r) => id == 'request:${r.id}')
      .firstOrNull;
  core.OrganizationTask? _organizationHistory(String id) =>
      owner.organizationTasks.where((t) => id == 'request:${t.id}').firstOrNull;
  bool _additionalRequest(String id) =>
      _credentialHistory(id) != null || _organizationHistory(id) != null;

  bool _credentialLive(core.CredentialUseRequest r) =>
      r.restoredAt == null &&
      !owner.credentialUseDecisionUnconfirmed(r) &&
      owner.credentialGrantState(r) == 'available';

  WorkspaceGrantState _credentialHistoryState(
    core.CredentialUseRequest r,
    _Entry? ordinary, {
    int? activeFieldCount,
  }) {
    if (r.restoredAt != null || owner.credentialUseDecisionUnconfirmed(r)) {
      return WorkspaceGrantState.unavailable;
    }
    final approved = r.approvedFields.length + (r.credentialApproved ? 1 : 0);
    final active =
        (r.credentialApproved && _credentialLive(r) ? 1 : 0) +
        (activeFieldCount ??
            ordinary?.grant?.fields
                .where(
                  (f) =>
                      r.approvedFields.contains(
                        core.FieldRef(f.itemId, f.fieldId),
                      ) &&
                      _active(ordinary.grant!, f),
                )
                .length ??
            0);
    if (active > 0) {
      return active == approved
          ? WorkspaceGrantState.active
          : WorkspaceGrantState.partial;
    }
    if (r.state == 'denied') return WorkspaceGrantState.denied;
    if (r.revokedAt != null || r.invalidatedCode == 'grant_revoked') {
      return WorkspaceGrantState.revoked;
    }
    if (r.invalidatedCode != null) return WorkspaceGrantState.unavailable;
    final session = owner.credentialRequestSessionId(r.id);
    if (session == null ||
        !owner.sessions.any((s) => s.id == session && !s.ended)) {
      return WorkspaceGrantState.sessionEnded;
    }
    if (owner.credentialUseState(r) == 'expired' ||
        owner.credentialGrantState(r) == 'expired' ||
        r.approvedFields.isNotEmpty &&
            owner.credentialFieldGrantState(r) == 'expired') {
      return WorkspaceGrantState.expired;
    }
    return WorkspaceGrantState.unavailable;
  }

  WorkspaceGrantSummary _credentialHistorySummary(
    core.CredentialUseRequest r,
    _Entry? ordinary, {
    WorkspaceGrantDetail? information,
  }) => WorkspaceGrantSummary(
    id: 'request:${r.id}',
    requestId: r.id,
    title: r.isFocusedFill ? '本机焦点填充申请' : '托管凭据使用申请',
    kind: r.isFocusedFill
        ? WorkspaceApprovalKind.focus
        : WorkspaceApprovalKind.credential,
    state: _credentialHistoryState(
      r,
      ordinary,
      activeFieldCount: information?.scopes.where((s) => s.active).length,
    ),
    agentClaim: '未提供 Agent 名称',
    chatClaim: r.chatLabel,
    purpose: r.purpose,
    recordedAt: r.decidedAt ?? r.createdAt,
    operationCount:
        (information?.summary.operationCount ??
            ((ordinary?.accesses.length ?? 0) +
                (ordinary?.deliveries.length ?? 0))) +
        owner.credentialExecutions.where((e) => e.requestId == r.id).length +
        owner.focusedFillOperations.where((f) => f.requestId == r.id).length,
  );

  WorkspaceGrantState _organizationHistoryState(core.OrganizationTask t) {
    if (owner.organizationState(t) == core.OrganizationTaskState.active &&
        t.approvedAt != null) {
      final valid = t.itemVersions.entries
          .where(
            (e) => owner.information.any(
              (i) => i.id == e.key && i.version == e.value,
            ),
          )
          .length;
      return valid == 0
          ? WorkspaceGrantState.unavailable
          : valid == t.itemVersions.length
          ? WorkspaceGrantState.active
          : WorkspaceGrantState.partial;
    }
    return switch (owner.organizationState(t)) {
      core.OrganizationTaskState.confirmed => WorkspaceGrantState.completed,
      core.OrganizationTaskState.rejected => WorkspaceGrantState.denied,
      core.OrganizationTaskState.expired => WorkspaceGrantState.expired,
      core.OrganizationTaskState.cancelled => WorkspaceGrantState.cancelled,
      core.OrganizationTaskState.proposed => WorkspaceGrantState.proposed,
      core.OrganizationTaskState.conflicted => WorkspaceGrantState.conflicted,
      _ => WorkspaceGrantState.unavailable,
    };
  }

  WorkspaceGrantSummary _organizationHistorySummary(core.OrganizationTask t) =>
      WorkspaceGrantSummary(
        id: 'request:${t.id}',
        requestId: t.id,
        title: '分类整理申请',
        kind: WorkspaceApprovalKind.organization,
        state: _organizationHistoryState(t),
        agentClaim: t.agentName.isEmpty ? '未提供 Agent 名称' : t.agentName,
        chatClaim: t.chatLabel,
        purpose: t.purpose,
        recordedAt: t.approvedAt ?? t.createdAt,
        operationCount: t.completedAt == null ? 0 : 1,
      );

  List<WorkspaceGrantSummary> _additionalSummaries(List<_Entry> ordinary) => [
    for (final r in owner.credentialUseRequests)
      if (owner.credentialUseState(r) != 'pending')
        _credentialHistorySummary(
          r,
          ordinary.where((e) => e.requestId == r.id).firstOrNull,
        ),
    for (final t in owner.organizationTasks)
      if (owner.organizationState(t) != core.OrganizationTaskState.pending)
        _organizationHistorySummary(t),
  ];

  Iterable<String> _historySearch(
    WorkspaceGrantSummary s,
    List<_Entry> ordinary,
  ) sync* {
    yield s.id;
    yield s.requestId ?? '';
    yield s.title;
    yield s.agentClaim;
    yield s.chatClaim;
    yield s.purpose;
    for (final e in ordinary.where((e) => e.requestId == s.requestId)) {
      yield e.request?.sessionId ?? e.grant!.sessionId;
      for (final f in e.fields) {
        yield f.itemName;
        yield f.fieldName;
      }
    }
    final r = _credentialHistory(s.id);
    if (r != null) {
      yield r.credentialName ??
          owner.credentials
              .where((c) => c.id == r.credentialId)
              .firstOrNull
              ?.name ??
          '';
      yield owner.credentialRequestSessionId(r.id) ?? '';
    }
    final t = _organizationHistory(s.id);
    if (t != null) {
      yield t.sessionBinding;
      for (final id in t.itemVersions.keys) {
        yield t.itemNames[id] ??
            owner.information.where((i) => i.id == id).firstOrNull?.name ??
            '';
      }
    }
  }

  Future<WorkspaceGrantDetail> _readAdditionalHistory(String id) async {
    final credential = _credentialHistory(id);
    if (credential != null) return _readCredentialHistory(id);
    var task = _organizationHistory(id)!;
    for (final item in task.itemVersions.keys) {
      await owner.revisionsFor(item);
    }
    task =
        _organizationHistory(id) ??
        (throw const WorkspaceFailure('not_found', '指定整理历史已清理。'));
    final state = _organizationHistoryState(task);
    return WorkspaceGrantDetail(
      summary: _organizationHistorySummary(task),
      reviewToken: OwnerWorkspaceAdditionalApprovals(
        owner,
      ).historyReviewToken(task.id),
      decidedAt: task.approvedAt,
      fieldExpiresAt: task.approvedAt == null ? null : task.expiresAt,
      scopes: [
        if (task.approvedAt != null)
          for (final e in task.itemVersions.entries)
            WorkspaceGrantedScope(
              id: e.key,
              record: WorkspaceRecordRef(
                WorkspaceRecordKind.information,
                e.key,
              ),
              label: task.itemNames[e.key] ?? '原资料名称未保留',
              recordVersion: e.value,
              kind: WorkspaceApprovalScopeKind.organization,
              active:
                  state.isActive &&
                  owner.information.any(
                    (i) => i.id == e.key && i.version == e.value,
                  ),
              expiresAt: task.expiresAt,
            ),
      ],
      targets: [
        for (final e in task.itemVersions.entries)
          WorkspaceGrantTarget(
            record: WorkspaceRecordRef(WorkspaceRecordKind.information, e.key),
            name:
                task.itemNames[e.key] ??
                owner.information
                    .where((i) => i.id == e.key)
                    .firstOrNull
                    ?.name ??
                '原资料名称未保留',
            version: task.approvedAt == null ? 0 : e.value,
            exists: owner.information.any((i) => i.id == e.key),
            snapshotAvailable:
                task.approvedAt != null &&
                _recordedVersion(e.key, e.value) != null,
          ),
      ],
      events: [
        if (task.approvedAt != null)
          WorkspaceGrantEvent(
            'organization-approved:${task.id}',
            task.approvedAt!,
            '主人批准分类整理范围',
            '固定${task.itemVersions.length}项资料；只允许元数据与分类调整，不代表已经应用整理。',
          ),
        if (task.completedAt != null)
          WorkspaceGrantEvent(
            'organization-result:${task.id}',
            task.completedAt!,
            '在固定范围内整理目录与标签',
            state.label,
            proposalId: task.id,
          ),
      ],
      scopeNotice:
          '整理范围与期限固定，只允许元数据与目录标签调整，不包含字段正文读取。当前状态：${owner.organizationState(task).name}。',
      legacyNotice: task.approvedAt == null
          ? '原记录未保存独立批准时间，不推断批准范围或当时快照。'
          : null,
    );
  }

  Future<WorkspaceGrantDetail> _readCredentialHistory(String id) async {
    WorkspaceGrantDetail? fields;
    try {
      fields = await _readInformationHistory(id, linkDecision: false);
    } on WorkspaceFailure catch (e) {
      if (e.code != 'not_found') rethrow;
    }
    final r =
        _credentialHistory(id) ??
        (throw const WorkspaceFailure('not_found', '指定凭据历史已清理。'));
    final projection = OwnerCredentialUseProjection(owner);
    final c = owner.credentials
        .where((c) => c.id == r.credentialId)
        .firstOrNull;
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.credential,
      r.credentialId,
    );
    final name = r.credentialName ?? c?.name ?? '原凭据名称未保留';
    final events =
        <WorkspaceGrantEvent>[
          ...?fields?.events,
          if (r.decidedAt != null)
            WorkspaceGrantEvent(
              'credential-decision:${r.id}',
              r.decidedAt!,
              '主人审批凭据与字段范围',
              r.state == 'denied'
                  ? '已拒绝，未启用凭据或字段范围。'
                  : '凭据${r.credentialApproved ? '已批准' : '未批准'}；普通字段批准${r.approvedFields.length}项。不代表已经执行或读取。',
            ),
          if (r.revokedAt != null)
            WorkspaceGrantEvent(
              'credential-revoked:${r.id}',
              r.revokedAt!,
              '主人撤销凭据申请',
              '本次范围已撤销，既有执行结果仍保留。',
            ),
          for (final e in owner.credentialExecutions.where(
            (e) => e.requestId == r.id,
          ))
            (() {
              final operation = projection.execution(r, e);
              return WorkspaceGrantEvent(
                'execution:${e.id}',
                e.finishedAt ?? e.startedAt ?? e.createdAt ?? r.createdAt,
                '${operation.plan.label} · 操作 ${operation.operationId} · 材料v${r.version}',
                '${operation.resultLabel}；进程${!operation.processStarted
                    ? '未确认启动'
                    : operation.processEnded
                    ? '已确认结束'
                    : '尚未确认结束'}；临时材料${operation.cleanup.label}${operation.fromBackup ? '；来自备份的历史事实，不接管原设备进程' : ''}',
              );
            })(),
          for (final f in owner.focusedFillOperations.where(
            (f) => f.requestId == r.id,
          ))
            WorkspaceGrantEvent(
              'focused-fill:${f.operationId}',
              f.createdAt,
              '本机焦点填充 · 操作 ${f.operationId}',
              f.state.name,
            ),
        ]..sort((a, b) {
          final time = b.at.compareTo(a.at);
          return time == 0 ? a.id.compareTo(b.id) : time;
        });
    return WorkspaceGrantDetail(
      summary: _credentialHistorySummary(r, null, information: fields),
      reviewToken: OwnerWorkspaceAdditionalApprovals(
        owner,
      ).historyReviewToken(r.id),
      decidedAt: r.decidedAt,
      fieldExpiresAt: r.fieldExpiresAt,
      credentialExpiresAt: r.credentialExpiresAt,
      credentialSessionBound:
          r.credentialValidity == core.CredentialUseValidity.session,
      scopes: [
        if (r.credentialApproved)
          WorkspaceGrantedScope(
            id: 'credential:${r.id}',
            record: ref,
            label: '$name · 材料v${r.version}',
            recordVersion: 0,
            materialVersion: r.version,
            kind: WorkspaceApprovalScopeKind.credential,
            active: _credentialLive(r),
            expiresAt: r.credentialExpiresAt,
          ),
        ...?fields?.scopes,
        for (final f in r.approvedFields)
          if (fields?.scopes.any(
                (s) => s.id == jsonEncode([f.itemId, f.fieldId]),
              ) !=
              true)
            WorkspaceGrantedScope(
              id: jsonEncode([f.itemId, f.fieldId]),
              record: WorkspaceRecordRef(
                WorkspaceRecordKind.information,
                f.itemId,
              ),
              label: '原字段名称未保留',
              recordVersion: 0,
              kind: WorkspaceApprovalScopeKind.field,
              active: false,
              expiresAt: r.fieldExpiresAt,
            ),
      ],
      targets: [
        WorkspaceGrantTarget(
          record: ref,
          name: name,
          version: 0,
          exists: c != null,
          snapshotAvailable: false,
        ),
        ...?fields?.targets,
        for (final id in r.approvedFields.map((f) => f.itemId).toSet())
          if (fields?.targets.any((t) => t.record.id == id) != true)
            WorkspaceGrantTarget(
              record: WorkspaceRecordRef(WorkspaceRecordKind.information, id),
              name: '原资料名称未保留',
              version: 0,
              exists: owner.information.any((i) => i.id == id),
              snapshotAvailable: false,
            ),
      ],
      events: events,
      scopeNotice:
          'SSH可在本聊天内不限时使用，其他凭据与普通字段按批准期限处理；每次使用独立记录。查询历史不会执行命令、领取材料或重新激活许可。${owner.credentialUseDecisionUnconfirmed(r) ? '原决定结果未确认，许可未启用。' : ''}',
      legacyNotice: r.restoredAt != null
          ? '来自备份的历史事实，不恢复原设备授权、进程或临时材料。'
          : fields?.legacyNotice,
    );
  }
}
