import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'owner_credential_use_projection.dart';
import 'workspace_source.dart';

/// Existing AI requests only. This adapter cannot initiate or execute a request.
class OwnerWorkspaceAdditionalApprovals {
  OwnerWorkspaceAdditionalApprovals(this.owner)
    : projection = OwnerCredentialUseProjection(owner);
  final core.OwnerAccess owner;
  final OwnerCredentialUseProjection projection;
  bool contains(String id) =>
      owner.credentialUseRequests.any((r) => r.id == id) ||
      owner.organizationTasks.any((r) => r.id == id);
  String _hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  WorkspaceApprovalState _credentialState(core.CredentialUseRequest r) {
    final s = projection.state(r);
    return switch (s) {
      WorkspaceCredentialRequestState.pending => WorkspaceApprovalState.pending,
      WorkspaceCredentialRequestState.denied => WorkspaceApprovalState.denied,
      WorkspaceCredentialRequestState.approved ||
      WorkspaceCredentialRequestState.partiallyApproved =>
        WorkspaceApprovalState.approved,
      WorkspaceCredentialRequestState.expired => WorkspaceApprovalState.expired,
      WorkspaceCredentialRequestState.unavailable =>
        WorkspaceApprovalState.unavailable,
      WorkspaceCredentialRequestState.sessionEnded =>
        WorkspaceApprovalState.sessionEnded,
      _ => WorkspaceApprovalState.revoked,
    };
  }

  WorkspaceApprovalState _organizationState(core.OrganizationTask t) =>
      switch (owner.organizationState(t)) {
        core.OrganizationTaskState.pending => WorkspaceApprovalState.pending,
        core.OrganizationTaskState.active => WorkspaceApprovalState.approved,
        core.OrganizationTaskState.rejected => WorkspaceApprovalState.denied,
        core.OrganizationTaskState.expired => WorkspaceApprovalState.expired,
        core.OrganizationTaskState.cancelled =>
          WorkspaceApprovalState.cancelled,
        _ => WorkspaceApprovalState.completed,
      };
  WorkspaceApprovalSummary credentialSummary(core.CredentialUseRequest r) =>
      WorkspaceApprovalSummary(
        id: r.id,
        title: r.isFocusedFill ? '本机焦点填充申请' : '托管凭据使用申请',
        kind: r.isFocusedFill
            ? WorkspaceApprovalKind.focus
            : WorkspaceApprovalKind.credential,
        agentClaim: '未提供 Agent 名称',
        sessionId: owner.credentialRequestSessionId(r.id) ?? 'unlinked:${r.id}',
        chatClaim: r.chatLabel,
        purpose: r.purpose,
        submittedAt: r.createdAt,
        requestExpiresAt: r.requestExpiresAt,
        state: _credentialState(r),
      );
  WorkspaceApprovalSummary organizationSummary(core.OrganizationTask t) =>
      WorkspaceApprovalSummary(
        id: t.id,
        title: '分类整理申请',
        kind: WorkspaceApprovalKind.organization,
        agentClaim: t.agentName.isEmpty ? '未提供 Agent 名称' : t.agentName,
        sessionId: t.sessionBinding,
        chatClaim: t.chatLabel,
        purpose: t.purpose,
        submittedAt: t.createdAt,
        requestExpiresAt: t.expiresAt,
        state: _organizationState(t),
      );
  List<WorkspaceApprovalSummary> summaries() => [
    for (final r in owner.credentialUseRequests) credentialSummary(r),
    for (final t in owner.organizationTasks) organizationSummary(t),
  ];
  core.CredentialUseRequest _credential(String id) =>
      owner.credentialUseRequests.singleWhere((r) => r.id == id);
  core.OrganizationTask _organization(String id) =>
      owner.organizationTasks.singleWhere((r) => r.id == id);

  /// Shared metadata stamp for history links and the original decision.
  String historyReviewToken(String id) {
    if (owner.credentialUseRequests.any((r) => r.id == id)) {
      final r = _credential(id);
      final c = owner.credentials
          .where((c) => c.id == r.credentialId)
          .firstOrNull;
      return _hash([
        r.toJson(),
        owner.credentialUseState(r),
        owner.credentialGrantState(r),
        for (final v in owner.informationRequests.where((v) => v.id == id))
          [v.state.name, v.sessionEnded, v.grantExpiresAt?.toIso8601String()],
        c?.revision,
        c == null ? null : owner.credentialAvailability(c).name,
        for (final f in r.fields)
          [
            f.toJson(),
            for (final i in owner.information.where((i) => i.id == f.itemId))
              [
                i.version,
                for (final field in i.fields.where((v) => v.id == f.fieldId))
                  [field.version, field.attachment?.toJson()],
              ],
          ],
      ]);
    }
    final t = _organization(id);
    return _hash([
      t.toJson(),
      owner.organizationState(t).name,
      for (final id in t.itemVersions.keys)
        [id, owner.information.where((i) => i.id == id).firstOrNull?.version],
      owner.templatePackageVersion,
    ]);
  }

  Future<WorkspaceApprovalDetail> read(String id) async {
    if (owner.credentialUseRequests.any((r) => r.id == id)) {
      return _readCredential(_credential(id));
    }
    final t = _organization(id);
    final scopes = [
      for (final id in t.itemVersions.keys)
        () {
          final item = owner.information.where((i) => i.id == id).firstOrNull;
          return WorkspaceApprovalScope(
            id: id,
            record: WorkspaceRecordRef(WorkspaceRecordKind.information, id),
            label: item?.name ?? t.itemNames[id] ?? '已移除资料',
            section: '分类整理',
            recordName: item?.name ?? t.itemNames[id] ?? '已移除资料',
            kind: WorkspaceApprovalScopeKind.organization,
            recordVersion: item?.version ?? 0,
            requested: true,
            available: item != null && item.version == t.itemVersions[id],
            unavailableReason: item == null
                ? '资料已移除。'
                : item.version != t.itemVersions[id]
                ? '资料已变化，请让 AI 重新申请范围。'
                : null,
          );
        }(),
    ];
    return WorkspaceApprovalDetail(
      request: organizationSummary(t),
      reviewToken: historyReviewToken(id),
      scopes: scopes,
      approved: t.approvedAt == null ? const [] : t.itemVersions.keys,
      decidedAt: t.approvedAt,
      fieldExpiresAt: t.approvedAt == null ? null : t.expiresAt,
    );
  }

  Future<WorkspaceApprovalDetail> _readCredential(
    core.CredentialUseRequest r,
  ) async {
    String? problem;
    try {
      owner.checkCredentialUseEligibility(r);
    } on core.CredentialUseFailure catch (e) {
      problem = '凭据或接收计划当前不可用（${e.code}）。';
    }
    final c = owner.credentials
        .where((v) => v.id == r.credentialId)
        .firstOrNull;
    final scopes = <WorkspaceApprovalScope>[
      WorkspaceApprovalScope(
        id: 'credential:${r.id}',
        record: WorkspaceRecordRef(
          WorkspaceRecordKind.credential,
          r.credentialId,
        ),
        label: r.isFocusedFill ? '托管材料填入已指定应用' : '在固定接收计划中使用托管材料',
        section: '托管凭据',
        recordName: r.credentialName ?? c?.name ?? '原凭据已不可用',
        kind: WorkspaceApprovalScopeKind.credential,
        recordVersion: c?.revision ?? 0,
        requested: true,
        available: problem == null,
        unavailableReason: problem,
      ),
    ];
    for (final ref in r.fields) {
      final item = owner.information
          .where((i) => i.id == ref.itemId)
          .firstOrNull;
      final f = item?.fields.where((f) => f.id == ref.fieldId).firstOrNull;
      final versions = <WorkspaceFileVersion>[];
      if (f?.attachment case final a?) {
        final v = (await owner.informationAttachmentVersions(
          a.attachmentId,
        )).where((v) => v.reference == a).firstOrNull;
        if (v != null) {
          versions.add(
            WorkspaceFileVersion(
              ref: WorkspaceFileRef(a.attachmentId, a.attachmentVersion),
              filename: v.originalName,
              mediaType: v.mediaType,
              byteLength: v.byteLength,
              createdAt: v.createdAt,
              available: v.available,
            ),
          );
        }
      }
      final file = f?.kind == core.FieldKind.file;
      final available =
          f != null &&
          r.restoredAt == null &&
          (!file ||
              owner.informationFileDeliveryAvailable &&
                  versions.singleOrNull?.available == true);
      scopes.add(
        WorkspaceApprovalScope(
          id: jsonEncode([ref.itemId, ref.fieldId]),
          record: WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            ref.itemId,
          ),
          label: f?.name ?? '已移除字段',
          section: item?.name ?? '已移除资料',
          recordName: item?.name ?? '已移除资料',
          kind: file
              ? WorkspaceApprovalScopeKind.file
              : WorkspaceApprovalScopeKind.field,
          recordVersion: item?.version ?? 0,
          fieldId: ref.fieldId,
          requested: true,
          available: available,
          unavailableReason: available ? null : '原字段或文件当前不可用。',
          fileVersions: versions,
        ),
      );
    }
    return WorkspaceApprovalDetail(
      request: credentialSummary(r),
      reviewToken: historyReviewToken(r.id),
      scopes: scopes,
      approved: [
        if (r.credentialApproved) 'credential:${r.id}',
        for (final f in r.approvedFields) jsonEncode([f.itemId, f.fieldId]),
      ],
      credential: projection.request(r),
      decidedAt: r.decidedAt,
      fieldExpiresAt: r.fieldExpiresAt,
      credentialExpiresAt: r.credentialExpiresAt,
      decisionUnavailableReason: owner.credentialUseDecisionUnconfirmed(r)
          ? '原决定的保存响应未能确认，许可没有启用；核对原结果后请让 AI 重新申请。'
          : null,
      executions: [
        if (!r.isFocusedFill)
          for (final e in owner.credentialExecutions.where(
            (e) => e.requestId == r.id,
          ))
            projection.execution(r, e),
      ],
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
  Future<WorkspaceApprovalReceipt?> receipt(String id) async {
    final r = await owner.additionalApprovalReceipt(id);
    return r == null ? null : _receipt(r);
  }

  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange c) async {
    final prior = await owner.additionalApprovalReceipt(c.operationId);
    if (prior != null) {
      if (prior.requestId != c.requestId ||
          prior.action.name != c.action.name ||
          prior.reviewToken != c.reviewToken ||
          prior.commandDigest != c.digest) {
        throw const WorkspaceFailure('conflict', '操作编号与原决定不同，请重新核对。');
      }
      return _receipt(prior);
    }
    final detail = await read(c.requestId);
    final originalToken = detail.reviewToken;
    void guard() {
      if (originalToken != c.reviewToken ||
          historyReviewToken(c.requestId) != originalToken) {
        throw const core.AccessFailure('scope_changed');
      }
    }

    guard();
    final approve = c.action == WorkspaceApprovalAction.approve;
    if (c.selected.toSet().length != c.selected.length ||
        (approve
            ? c.selected.isEmpty ||
                  detail.request.state != WorkspaceApprovalState.pending
            : c.selected.isNotEmpty || c.fileVersions.isNotEmpty)) {
      throw const WorkspaceFailure('invalid_scope', '请核对所选范围和申请状态。');
    }
    final scopes = {for (final s in detail.scopes) s.id: s};
    if (c.selected.any(
      (id) => scopes[id]?.available != true || scopes[id]?.requested != true,
    )) {
      throw const WorkspaceFailure('conflict', '所选范围已不可用，请重新核对。');
    }
    final files = c.selected
        .where((id) => scopes[id]!.kind == WorkspaceApprovalScopeKind.file)
        .toList();
    if (c.fileVersions.length != files.length ||
        files.any(
          (id) =>
              scopes[id]!.fileVersions.singleOrNull?.ref.version !=
              c.fileVersions[id],
        )) {
      throw const WorkspaceFailure('conflict', '文件版本已变化，请重新核对。');
    }
    final credential = owner.credentialUseRequests.any(
      (r) => r.id == c.requestId,
    );
    Future<void> decide() async {
      if (credential) {
        final r = _credential(c.requestId);
        if (c.action == WorkspaceApprovalAction.revoke) {
          await owner.revokeCredentialRequest(r.id);
          return;
        }
        final refs = [
          for (final id in c.selected)
            if (scopes[id]!.fieldId != null)
              core.FieldRef(scopes[id]!.record.id, scopes[id]!.fieldId!),
        ];
        if (approve &&
            (!const [15, 30].contains(c.credentialMinutes) ||
                !(r.protocolVersion == 2
                        ? const [15, 30, 60, 480]
                        : const [15, 30])
                    .contains(c.fieldMinutes))) {
          throw const WorkspaceFailure(
            'invalid_scope',
            '凭据支持15或30分钟；普通字段请选择协议支持的期限。',
          );
        }
        await owner.decideCredentialUse(
          r.id,
          approveCredential:
              approve && c.selected.contains('credential:${r.id}'),
          fields: refs,
          lifetime: Duration(minutes: c.credentialMinutes),
          fieldLifetime: Duration(minutes: c.fieldMinutes),
          reviewedVersions: {
            for (final f in refs)
              f: owner.information
                  .singleWhere((i) => i.id == f.itemId)
                  .fields
                  .singleWhere((v) => v.id == f.fieldId)
                  .version,
          },
        );
      } else {
        final t = _organization(c.requestId);
        switch (c.action) {
          case WorkspaceApprovalAction.approve:
            if (c.fieldMinutes < 1 || c.fieldMinutes > 30) {
              throw const WorkspaceFailure('invalid_scope', '整理权限最长30分钟。');
            }
            await owner.approveOrganization(
              t.id,
              c.selected,
              lifetime: Duration(minutes: c.fieldMinutes),
            );
          case WorkspaceApprovalAction.deny:
            await owner.denyOrganization(t.id);
          case WorkspaceApprovalAction.revoke:
            await owner.cancelOrganization(t.id);
        }
      }
    }

    try {
      return _receipt(
        await owner.performAdditionalApproval(
          operationId: c.operationId,
          requestId: c.requestId,
          kind: credential ? 'credential' : 'organization',
          action: core.InformationApprovalAction.values.byName(c.action.name),
          reviewToken: c.reviewToken,
          commandDigest: c.digest,
          validate: guard,
          decide: decide,
        ),
      );
    } on core.CredentialUseFailure catch (e) {
      throw WorkspaceFailure(
        e.code == 'audit_unavailable' ? 'unknown_outcome' : 'conflict',
        e.code == 'audit_unavailable'
            ? '决定结果尚未确认，请核对原操作。'
            : '申请或使用范围当前不可用（${e.code}），请重新核对。',
      );
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(
        e.status == 'scope_changed' ? 'conflict' : e.status,
        '申请、范围或原操作已变化，请重新核对。',
      );
    } on WorkspaceFailure {
      rethrow;
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '决定结果尚未确认，请核对原操作。');
    }
  }

  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) async {
    final r = _credential(requestId);
    final matches = owner.credentialExecutions
        .where(
          (e) =>
              e.requestId == requestId &&
              (e.operationId ?? e.id) == operationId,
        )
        .toList();
    if (matches.length != 1) {
      throw const WorkspaceFailure('unknown_outcome', '此执行结果尚未确认；查询不会重放执行。');
    }
    return projection.execution(r, matches.single);
  }
}
