import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_source.dart';

/// The same inbox/selectable scope contract as ordinary requests. All decisions
/// and their recovery receipts commit in the batch repository's one write.
class OwnerWorkspaceCredentialBatches {
  OwnerWorkspaceCredentialBatches(this.owner);
  final core.OwnerAccess owner;
  bool contains(String id) => owner.credentialBatches.any((r) => r.id == id);
  core.CredentialUseBatch _request(String id) =>
      owner.credentialBatches.where((r) => r.id == id).firstOrNull ??
      (throw const WorkspaceFailure('not_found', '未找到这条凭据申请。'));

  WorkspaceApprovalState _state(core.CredentialUseBatch r) {
    final state = owner.credentialBatchState(r);
    if (state == 'approved' || state == 'partially_approved') {
      final states = r.items
          .where((i) => i.decision == core.CredentialBatchItemDecision.approved)
          .map((i) => owner.credentialBatchItemState(r, i))
          .toList();
      if (states.contains('available')) return WorkspaceApprovalState.approved;
      if (states.isNotEmpty && states.every((s) => s == 'expired')) {
        return WorkspaceApprovalState.expired;
      }
      return WorkspaceApprovalState.unavailable;
    }
    return switch (state) {
      'pending' => WorkspaceApprovalState.pending,
      'denied' => WorkspaceApprovalState.denied,
      'revoked' => WorkspaceApprovalState.revoked,
      'expired' => WorkspaceApprovalState.expired,
      'cancelled' => WorkspaceApprovalState.cancelled,
      _ => WorkspaceApprovalState.sessionEnded,
    };
  }

  WorkspaceApprovalSummary summary(
    core.CredentialUseBatch r,
  ) => WorkspaceApprovalSummary(
    id: r.id,
    title: r.items.length == 1
        ? '${r.items.single.credentialName} · 凭据使用'
        : '${r.items.length}份凭据使用申请',
    kind: WorkspaceApprovalKind.credential,
    agentClaim: r.agentName,
    // A display grouping only; it is never accepted as a session capability.
    sessionId: r.sessionBinding,
    chatClaim: core.submissionChatLabel(r.chatLabel, r.externalChatId),
    purpose: r.purpose,
    submittedAt: r.createdAt,
    requestExpiresAt: r.requestExpiresAt,
    state: _state(r),
  );
  List<WorkspaceApprovalSummary> summaries() =>
      owner.credentialBatches.map(summary).toList();

  static String destinationLabel(core.CredentialBatchDestination d) {
    final browser = d.browser;
    return browser == null
        ? '本机密码框 · ${d.application!.executable}'
        : '${d.via == 'ego' ? 'Ego' : 'Chrome'} · ${browser.url}\n表单：${browser.formSelector}\n密码框：${browser.fieldSelector}';
  }

  static String scopeLabel(core.CredentialBatchItem item) =>
      '第${item.version}版 · ${destinationLabel(item.destination)}';

  WorkspaceCredentialBatchOperation operationView(
    core.CredentialUseBatch r,
    core.CredentialBatchOperation operation,
  ) => WorkspaceCredentialBatchOperation.fromJson({
    ...owner.credentialBatchOperationView(operation),
    'attentionOperationId': operation.attentionOperationId,
    'fromBackup': r.archived,
  });
  WorkspaceCredentialBatchOperation operation(
    String requestId,
    String operationId,
  ) {
    final r = _request(requestId);
    final operation = owner.credentialBatchOperations
        .where((o) => o.requestId == requestId && o.operationId == operationId)
        .firstOrNull;
    if (operation == null) {
      throw const WorkspaceFailure('not_found', '未找到这次填写记录。');
    }
    return operationView(r, operation);
  }

  Future<WorkspaceCredentialBatchOperation> acknowledge(
    WorkspaceCredentialBatchAcknowledgement change,
  ) async {
    final r = _request(change.requestId);
    try {
      final result = await owner.acknowledgeCredentialBatchOperation(
        r.id,
        change.operationId,
        ownerOperationId: change.ownerOperationId,
        revision: change.revision,
      );
      return operationView(r, result);
    } on core.CredentialUseFailure catch (error) {
      throw WorkspaceFailure(
        error.code == 'audit_unavailable' ? 'unknown_outcome' : 'conflict',
        error.code == 'audit_unavailable'
            ? '无法确认核对结果，请查询原操作。'
            : '填写记录已变化，请重新读取后核对。',
      );
    }
  }

  String reviewToken(String id) {
    final r = _request(id);
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              r.toJson(),
              owner.credentialBatchState(r),
              for (final item in r.items)
                [
                  item.id,
                  owner.credentialBatchItemState(r, item),
                  owner.credentials
                      .where((c) => c.id == item.credentialId)
                      .firstOrNull
                      ?.revision,
                ],
            ]),
          ),
        )
        .toString();
  }

  WorkspaceApprovalDetail read(String id) {
    final r = _request(id);
    final scopes = <WorkspaceApprovalScope>[];
    for (final item in r.items) {
      String? problem;
      try {
        owner.checkCredentialBatchItemEligibility(item);
      } on core.CredentialUseFailure {
        problem = '凭据已变化或不可用，请让 AI 重新申请。';
      }
      if (r.decisions.isNotEmpty && problem == null) {
        problem = switch (owner.credentialBatchItemState(r, item)) {
          'available' => null,
          'denied' => '这份凭据未获批准。',
          'revoked' => '这份凭据的许可已撤销或失效。',
          'expired' => '这份凭据的使用期限已到。',
          'version_invalidated' => '凭据已更新，需要重新申请。',
          _ => '这份凭据的许可已不可用。',
        };
      }
      scopes.add(
        WorkspaceApprovalScope(
          id: item.id,
          record: WorkspaceRecordRef(
            WorkspaceRecordKind.credential,
            item.credentialId,
          ),
          label: scopeLabel(item),
          section: item.credentialName,
          recordName: item.credentialName,
          kind: WorkspaceApprovalScopeKind.credential,
          recordVersion: item.version,
          requested: true,
          available: problem == null && !r.archived,
          unavailableReason: r.archived ? '这条历史记录不能恢复原聊天的许可。' : problem,
        ),
      );
    }
    return WorkspaceApprovalDetail(
      request: summary(r),
      reviewToken: reviewToken(id),
      scopes: scopes,
      credentialBatch: true,
      batchOperations: [
        for (final o in owner.credentialBatchOperations)
          if (o.requestId == r.id) operationView(r, o),
      ],
      approved: r.items
          .where((i) => i.decision == core.CredentialBatchItemDecision.approved)
          .map((i) => i.id),
      decidedAt: r.decisions.firstOrNull?.at,
      credentialExpiresAt: r.items
          .where(
            (i) => {
              core.CredentialBatchItemDecision.approved,
              core.CredentialBatchItemDecision.revoked,
            }.contains(i.decision),
          )
          .map((i) => i.expiresAt)
          .firstOrNull,
    );
  }

  WorkspaceApprovalReceipt _receipt(core.InformationApprovalReceipt r) =>
      WorkspaceApprovalReceipt(
        operationId: r.operationId,
        requestId: r.requestId,
        action: WorkspaceApprovalAction.values.byName(r.action.name),
        reviewToken: r.reviewToken,
        revision: r.revision,
        commandDigest: r.commandDigest,
      );
  WorkspaceApprovalReceipt? receipt(String id) {
    final r = owner.credentialBatchApprovalReceipt(id);
    return r == null ? null : _receipt(r);
  }

  Future<WorkspaceApprovalReceipt> change(
    WorkspaceApprovalChange change,
  ) async {
    final prior = receipt(change.operationId);
    if (prior != null) {
      if (!prior.matches(change)) {
        throw const WorkspaceFailure('conflict', '原操作编号不能用于另一项决定。');
      }
      return prior;
    }
    final r = _request(change.requestId);
    final detail = read(r.id);
    void guard() {
      if (reviewToken(r.id) != change.reviewToken) {
        throw const core.CredentialUseFailure('operation_conflict');
      }
    }

    guard();
    final approve = change.action == WorkspaceApprovalAction.approve;
    if (change.fileVersions.isNotEmpty ||
        change.selected.toSet().length != change.selected.length ||
        (approve
            ? change.selected.isEmpty ||
                  detail.request.state != WorkspaceApprovalState.pending ||
                  change.selected.any(
                    (id) =>
                        !detail.scopes.any((s) => s.id == id && s.available),
                  ) ||
                  change.credentialMinutes == null
            : change.action == WorkspaceApprovalAction.deny
            ? change.selected.isNotEmpty
            : change.selected.any(
                (id) => !r.items.any(
                  (i) =>
                      i.id == id &&
                      i.decision == core.CredentialBatchItemDecision.approved,
                ),
              ))) {
      throw const WorkspaceFailure('invalid_scope', '请核对凭据、填写位置和使用期限。');
    }
    try {
      if (change.action == WorkspaceApprovalAction.revoke) {
        await owner.revokeCredentialBatch(
          r.id,
          operationId: change.operationId,
          revision: r.revision,
          itemIds: change.selected.isNotEmpty
              ? change.selected
              : r.items
                    .where(
                      (i) =>
                          i.decision ==
                          core.CredentialBatchItemDecision.approved,
                    )
                    .map((i) => i.id),
          reviewToken: change.reviewToken,
          commandDigest: change.digest,
          validateReview: guard,
        );
      } else {
        await owner.decideCredentialBatch(
          r.id,
          operationId: change.operationId,
          revision: r.revision,
          approvedItems: approve ? change.selected : const [],
          lifetime: Duration(
            minutes:
                change.credentialMinutes ?? core.AccessTiming.defaultMinutes,
          ),
          reviewToken: change.reviewToken,
          commandDigest: change.digest,
          validateReview: guard,
        );
      }
      return receipt(change.operationId) ??
          (throw const WorkspaceFailure(
            'unknown_outcome',
            '决定结果尚未确认，请先核对原操作。',
          ));
    } on core.CredentialUseFailure catch (e) {
      throw WorkspaceFailure(
        e.code == 'audit_unavailable' ? 'unknown_outcome' : 'conflict',
        e.code == 'audit_unavailable' ? '决定结果尚未确认，请先核对原操作。' : '凭据申请已变化，请重新核对。',
      );
    }
  }
}
