part of 'owner_workspace_grant_history.dart';

extension _BatchGrantHistory on OwnerWorkspaceGrantHistory {
  core.CredentialUseBatch? _batchHistory(String id) =>
      owner.credentialBatches.where((r) => id == 'request:${r.id}').firstOrNull;

  WorkspaceGrantState _batchHistoryState(core.CredentialUseBatch r) {
    if (r.archived) return WorkspaceGrantState.unavailable;
    final state = owner.credentialBatchState(r);
    if (state == 'denied') return WorkspaceGrantState.denied;
    if (state == 'revoked') return WorkspaceGrantState.revoked;
    if (state == 'expired') return WorkspaceGrantState.expired;
    if (state == 'cancelled') return WorkspaceGrantState.cancelled;
    final approved = r.items
        .where((i) => i.decision == core.CredentialBatchItemDecision.approved)
        .toList();
    final states = approved
        .map((i) => owner.credentialBatchItemState(r, i))
        .toList();
    final active = states.where((s) => s == 'available').length;
    if (active > 0) {
      return active == r.items.length
          ? WorkspaceGrantState.active
          : WorkspaceGrantState.partial;
    }
    if (states.isNotEmpty && states.every((s) => s == 'expired')) {
      return WorkspaceGrantState.expired;
    }
    if (!owner.sessions.any((s) => s.id == r.sessionBinding && !s.ended)) {
      return WorkspaceGrantState.sessionEnded;
    }
    return WorkspaceGrantState.unavailable;
  }

  WorkspaceGrantSummary _batchHistorySummary(core.CredentialUseBatch r) =>
      WorkspaceGrantSummary(
        id: 'request:${r.id}',
        requestId: r.id,
        title: OwnerWorkspaceCredentialBatches(owner).summary(r).title,
        kind: WorkspaceApprovalKind.credential,
        state: _batchHistoryState(r),
        agentClaim: r.agentName,
        chatClaim: core.submissionChatLabel(r.chatLabel, r.externalChatId),
        purpose: r.purpose,
        recordedAt: r.decisions.lastOrNull?.at ?? r.createdAt,
        operationCount: r.programPlan != null
            ? owner.credentialProgramOperations
                  .where((operation) => operation.requestId == r.id)
                  .length
            : owner.credentialBatchOperations
                  .where((o) => o.requestId == r.id)
                  .length,
      );

  String _batchResult(String state) =>
      WorkspaceCredentialBatchOperation.resultLabel(state);

  WorkspaceGrantDetail _readBatchHistory(core.CredentialUseBatch r) {
    final operations = owner.credentialBatchOperations
        .where((o) => o.requestId == r.id)
        .toList();
    final programs = r.programPlan == null
        ? <WorkspaceCredentialProgramOperation>[]
        : owner.credentialProgramOperations
              .where((operation) => operation.requestId == r.id)
              .map(OwnerWorkspaceCredentialBatches(owner).programOperationView)
              .toList();
    final pending = operations
        .where(
          (o) =>
              o.attentionAcknowledgedAt == null &&
              {'partial', 'unknown'}.contains(
                owner.credentialBatchOperationView(o)['executionState'],
              ),
        )
        .length;
    final names = {for (final i in r.items) i.id: i.credentialName};
    final events =
        <WorkspaceGrantEvent>[
          for (final (index, d) in r.decisions.indexed)
            WorkspaceGrantEvent(
              'batch-decision:${d.operationId}',
              d.at,
              index == 0 ? '用户审批凭据使用' : '撤销凭据使用许可',
              index == 0
                  ? '批准${r.items.where((i) => i.decision != core.CredentialBatchItemDecision.denied).length}项，拒绝${r.items.where((i) => i.decision == core.CredentialBatchItemDecision.denied).length}项。${r.programPlan == null ? '批准不代表已填写。' : '批准不代表程序已启动。'}'
                  : '已撤销的范围不能继续使用，既有使用结果仍保留。',
            ),
          for (final operation in programs)
            WorkspaceGrantEvent(
              'program-operation:${operation.operationId}',
              operation.finishedAt ?? operation.createdAt,
              '运行 ${operation.plan.executable.split(RegExp(r'[/\\]')).last}',
              [
                operation.resultLabel,
                operation.cleanupLabel,
                if (operation.errorLabel != null && !operation.fromBackup)
                  operation.errorLabel!,
                '使用${operation.itemIds.map((id) => names[id] ?? '凭据').toSet().join('、')}',
                if (operation.fromBackup) '来自备份的执行历史。',
              ].join('\n'),
            ),
          for (final operation in operations)
            (() {
              final view = owner.credentialBatchOperationView(operation);
              final metadata = OwnerWorkspaceCredentialBatches(
                owner,
              ).operationView(r, operation);
              final result = <String>[
                _batchResult(view['executionState'] as String),
                if (metadata.errorLabel != null) metadata.errorLabel!,
                for (final entry in operation.itemResults.entries)
                  '${names[entry.key] ?? '凭据'}：${_batchResult(entry.value)}',
                if (r.archived) '来自备份的历史，不能恢复原聊天的许可。',
              ];
              return WorkspaceGrantEvent(
                'batch-operation:${operation.operationId}',
                operation.finishedAt ?? operation.createdAt,
                '填写${operation.itemIds.map((id) => names[id] ?? '凭据').join('、')}',
                result.join('\n'),
              );
            })(),
          for (final operation in operations)
            if (operation.attentionAcknowledgedAt != null)
              WorkspaceGrantEvent(
                'batch-attention:${operation.operationId}',
                operation.attentionAcknowledgedAt!,
                '用户已核对原操作与目标',
                '允许发起新的填写，原操作结果仍按实际记录保留。',
              ),
        ]..sort((a, b) {
          final at = b.at.compareTo(a.at);
          return at == 0 ? a.id.compareTo(b.id) : at;
        });
    return WorkspaceGrantDetail(
      summary: _batchHistorySummary(r),
      reviewToken: OwnerWorkspaceCredentialBatches(owner).reviewToken(r.id),
      credentialSessionBound: OwnerWorkspaceCredentialBatches.sessionBound(r),
      decidedAt: r.decisions.firstOrNull?.at,
      scopes: [
        for (final item in r.items)
          if ({
            core.CredentialBatchItemDecision.approved,
            core.CredentialBatchItemDecision.revoked,
          }.contains(item.decision))
            WorkspaceGrantedScope(
              id: item.id,
              record: WorkspaceRecordRef(
                WorkspaceRecordKind.credential,
                item.credentialId,
              ),
              label:
                  '${item.credentialName} · ${OwnerWorkspaceCredentialBatches.scopeLabel(item)}',
              recordVersion: 0,
              materialVersion: item.version,
              kind: WorkspaceApprovalScopeKind.credential,
              active: owner.credentialBatchItemState(r, item) == 'available',
              expiresAt: item.expiresAt,
            ),
      ],
      targets: [
        for (final id in r.items.map((i) => i.credentialId).toSet())
          WorkspaceGrantTarget(
            record: WorkspaceRecordRef(WorkspaceRecordKind.credential, id),
            name: r.items
                .firstWhere((i) => i.credentialId == id)
                .credentialName,
            version: 0,
            exists: owner.credentials.any((c) => c.id == id),
            snapshotAvailable: false,
          ),
      ],
      events: events,
      scopeNotice: r.archived
          ? null
          : programs.any((operation) => operation.state == 'unknown')
          ? '有程序执行结果未确认。请查询原操作，不要重新启动。'
          : pending == 0
          ? null
          : '有$pending次填写结果需要核对。请打开对应申请查看详情；不会自动再次填写。',
    );
  }
}
