import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_approvals.dart';
import 'workspace_records.dart';

/// Ordinary request metadata from the actual service and retained audit facts.
/// It neither creates requests nor retains values, private proofs or tokens.
class OwnerWorkspaceApprovals implements WorkspaceApprovalSource {
  OwnerWorkspaceApprovals({required this.owner})
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  static const _decisionUnavailable = '此版本的审批操作尚未接入。';

  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await owner.inLibraryScope(_scope, action);
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, switch (e.status) {
        'library_changed' => '资料库已替换，请重新打开收件箱。',
        'audit_unavailable' => '申请历史暂时无法确认，请稍后重试。',
        _ => '申请服务暂时不可用，请稍后重试。',
      });
    }
  }

  static WorkspaceApprovalState stateOf(core.OwnerRequestSnapshot r) {
    if (r.sessionEnded ||
        r.applicationClosed ||
        (r.historical && r.state == core.AccessRequestState.approved)) {
      return WorkspaceApprovalState.sessionEnded;
    }
    return switch (r.state) {
      core.AccessRequestState.pending =>
        r.historical
            ? WorkspaceApprovalState.unavailable
            : WorkspaceApprovalState.pending,
      core.AccessRequestState.approved => WorkspaceApprovalState.approved,
      core.AccessRequestState.denied => WorkspaceApprovalState.denied,
      core.AccessRequestState.expired => WorkspaceApprovalState.expired,
      core.AccessRequestState.cancelled => WorkspaceApprovalState.cancelled,
      core.AccessRequestState.revoked => WorkspaceApprovalState.revoked,
    };
  }

  static WorkspaceApprovalSummary summaryOf(core.OwnerRequestSnapshot r) =>
      WorkspaceApprovalSummary(
        id: r.id,
        title: '资料读取申请',
        kind: WorkspaceApprovalKind.information,
        agentClaim: '未提供 Agent 名称',
        sessionId: r.sessionId,
        chatClaim: r.chatLabel,
        purpose: r.purpose,
        submittedAt: r.createdAt,
        requestExpiresAt: r.requestExpiresAt,
        state: stateOf(r),
      );

  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery query, {
    String? keepSelection,
  }) => _read(() async {
    if (query.offset < 0 ||
        query.limit < 1 ||
        query.limit > 100 ||
        query.keyword.length > 2000) {
      throw const WorkspaceFailure('invalid_query', '申请查询条件无效。');
    }
    final needle = query.keyword.trim().toLowerCase();
    final matching = (await owner.informationRequestInbox())
        .where(
          (r) =>
              needle.isEmpty ||
              [
                r.id,
                r.sessionId,
                r.chatLabel,
                r.purpose,
                ...r.recordedFields.expand((f) => [f.itemName, f.fieldName]),
              ].any((s) => s.toLowerCase().contains(needle)),
        )
        .toList();
    final pending = matching
        .where((r) => stateOf(r) == WorkspaceApprovalState.pending)
        .length;
    final filtered =
        matching
            .where(
              (r) => switch (query.filter) {
                WorkspaceApprovalFilter.all => true,
                WorkspaceApprovalFilter.pending =>
                  stateOf(r) == WorkspaceApprovalState.pending,
                WorkspaceApprovalFilter.done =>
                  stateOf(r) != WorkspaceApprovalState.pending,
              },
            )
            .toList()
          ..sort((a, b) {
            final time = b.createdAt.compareTo(a.createdAt);
            return time != 0 ? time : a.id.compareTo(b.id);
          });
    final offset = filtered.isEmpty
        ? 0
        : min(query.offset, (filtered.length - 1) ~/ query.limit * query.limit);
    final selectedIndex = filtered.indexWhere((r) => r.id == keepSelection);
    final index = filtered.isEmpty
        ? null
        : selectedIndex >= 0
        ? selectedIndex
        : offset;
    return WorkspaceApprovalResults(
      items: filtered.skip(offset).take(query.limit).map(summaryOf),
      total: filtered.length,
      pending: pending,
      offset: offset,
      selection: index == null ? null : filtered[index].id,
      selectionIndex: index,
    );
  });

  @override
  Future<WorkspaceApprovalDetail> read(String id) => _read(() async {
    final r = (await owner.informationRequestInbox())
        .where((r) => r.id == id)
        .firstOrNull;
    if (r == null) {
      throw const WorkspaceFailure('not_found', '未找到这条申请或历史已按保留规则清理。');
    }
    final records = {for (final item in owner.information) item.id: item};
    final names = {
      for (final f in r.recordedFields) core.FieldRef(f.itemId, f.fieldId): f,
    };
    final refs = {...r.fields, ...?r.approvedFields};
    String key(core.FieldRef ref) => jsonEncode([ref.itemId, ref.fieldId]);
    final scopes = [
      for (final ref in refs)
        () {
          final item = records[ref.itemId];
          final field = item?.fields
              .where((f) => f.id == ref.fieldId)
              .firstOrNull;
          return WorkspaceApprovalScope(
            id: key(ref),
            record: WorkspaceRecordRef(
              WorkspaceRecordKind.information,
              ref.itemId,
            ),
            label: field?.name ?? names[ref]?.fieldName ?? '已移除字段',
            section: '资料字段',
            recordName: item?.name ?? names[ref]?.itemName ?? '已移除资料',
            kind: field?.kind == core.FieldKind.file
                ? WorkspaceApprovalScopeKind.file
                : WorkspaceApprovalScopeKind.field,
            recordVersion: item?.version ?? 0,
            fieldId: ref.fieldId,
            requested: r.fields.contains(ref),
            available: field != null && !r.historical,
            unavailableReason: field == null
                ? '原字段已不存在。'
                : r.historical
                ? '历史记录不授予访问能力。'
                : null,
          );
        }(),
    ];
    return WorkspaceApprovalDetail(
      request: summaryOf(r),
      reviewToken: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                r.id,
                stateOf(r).name,
                r.requestExpiresAt.toIso8601String(),
                r.grantExpiresAt?.toIso8601String(),
                for (final s in scopes) [s.id, s.recordVersion, s.available],
              ]),
            ),
          )
          .toString(),
      scopes: scopes,
      approved: (r.approvedFields ?? []).map(key),
      decidedAt: r.approvedAt,
      fieldExpiresAt: r.grantExpiresAt,
      decisionUnavailableReason: _decisionUnavailable,
    );
  });

  @override
  Future<WorkspaceApprovalReceipt> change(
    WorkspaceApprovalChange change,
  ) async => throw const WorkspaceFailure('unsupported', _decisionUnavailable);
  @override
  Future<WorkspaceApprovalReceipt?> receipt(String operationId) async =>
      throw const WorkspaceFailure('unsupported', '审批操作回执尚未接入，不能确认原操作。');
  @override
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) async => throw const WorkspaceFailure('unsupported', '普通资料读取没有凭据执行结果。');
}
