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
      final d = item.destination;
      final browser = d.browser;
      final destination = browser == null
          ? '本机密码框 · ${d.application!.executable}'
          : '${d.via == 'ego' ? 'Ego' : 'Chrome'} · ${browser.url}\n表单：${browser.formSelector}\n密码框：${browser.fieldSelector}';
      scopes.add(
        WorkspaceApprovalScope(
          id: item.id,
          record: WorkspaceRecordRef(
            WorkspaceRecordKind.credential,
            item.credentialId,
          ),
          label: '第${item.version}版 · $destination',
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
      approved: r.items
          .where((i) => i.decision == core.CredentialBatchItemDecision.approved)
          .map((i) => i.id),
      decidedAt: r.decisions.firstOrNull?.at,
      credentialExpiresAt: r.items
          .where((i) => i.decision == core.CredentialBatchItemDecision.approved)
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
            : change.selected.isNotEmpty)) {
      throw const WorkspaceFailure('invalid_scope', '请核对凭据、填写位置和使用期限。');
    }
    try {
      if (change.action == WorkspaceApprovalAction.revoke) {
        await owner.revokeCredentialBatch(
          r.id,
          operationId: change.operationId,
          revision: r.revision,
          itemIds: r.items
              .where(
                (i) => i.decision == core.CredentialBatchItemDecision.approved,
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
