import 'owner_workspace_additional_approvals.dart';
import 'owner_workspace_credential_batches.dart';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_approvals.dart';
import 'workspace_records.dart';
import 'workspace_files.dart';

/// Ordinary owner decisions and metadata from the actual service.
/// Requests still originate in Agent transport; this source never retains values,
/// private session proofs or read tokens.
class OwnerWorkspaceApprovals
    implements
        WorkspaceApprovalSource,
        WorkspaceCredentialBatchActions,
        WorkspaceCredentialProgramActions {
  OwnerWorkspaceApprovals({required this.owner})
    : _scope = owner.captureLibraryScope(),
      _additional = OwnerWorkspaceAdditionalApprovals(owner);
  final core.OwnerAccess owner;
  final OwnerWorkspaceAdditionalApprovals _additional;
  final core.OwnerLibraryScope _scope;

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

  static WorkspaceApprovalSummary summaryOf(
    core.OwnerRequestSnapshot r, {
    bool file = false,
  }) => WorkspaceApprovalSummary(
    id: r.id,
    title: file ? '文件与字段申请' : '资料读取申请',
    kind: file ? WorkspaceApprovalKind.file : WorkspaceApprovalKind.information,
    agentClaim: r.agentName,
    sessionId: r.sessionId,
    chatClaim: core.submissionChatLabel(r.chatLabel, r.externalChatId),
    purpose: r.purpose,
    submittedAt: r.createdAt,
    requestExpiresAt: r.requestExpiresAt,
    state: stateOf(r),
  );

  bool _hasCurrentFile(core.OwnerRequestSnapshot r) => r.fields.any(
    (ref) =>
        owner.information
            .where((i) => i.id == ref.itemId)
            .firstOrNull
            ?.fields
            .where((f) => f.id == ref.fieldId)
            .firstOrNull
            ?.kind ==
        core.FieldKind.file,
  );

  Future<WorkspaceFileVersion?> _currentFile(
    core.InformationAttachmentRef ref,
  ) async {
    try {
      final v = (await owner.informationAttachmentVersions(
        ref.attachmentId,
      )).where((v) => v.reference == ref).firstOrNull;
      return v == null
          ? null
          : WorkspaceFileVersion(
              ref: WorkspaceFileRef(ref.attachmentId, ref.attachmentVersion),
              filename: v.originalName,
              mediaType: v.mediaType,
              byteLength: v.byteLength,
              createdAt: v.createdAt,
              available: v.available,
            );
    } on core.AccessFailure catch (e) {
      if ({
        'attachment_missing',
        'attachment_integrity_failed',
        'invalid_information_file',
      }.contains(e.status)) {
        return null;
      }
      rethrow;
    }
  }

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
    final credentialIds = owner.credentialUseRequests.map((r) => r.id).toSet();
    final ordinary = await owner.informationRequestInbox();
    final metadataMatches = <String>{
      for (final r in ordinary)
        if (r.recordedFields.any(
          (f) =>
              f.itemName.toLowerCase().contains(needle) ||
              f.fieldName.toLowerCase().contains(needle),
        ))
          r.id,
      for (final r in owner.credentialUseRequests)
        if ((r.credentialName ?? '').toLowerCase().contains(needle)) r.id,
      for (final r in owner.credentialBatches)
        if (r.items.any((i) => i.credentialName.toLowerCase().contains(needle)))
          r.id,
      for (final t in owner.organizationTasks)
        if (t.itemNames.values.any((n) => n.toLowerCase().contains(needle)))
          t.id,
    };
    final matching =
        <WorkspaceApprovalSummary>[
              for (final r in ordinary)
                if (!credentialIds.contains(r.id))
                  summaryOf(r, file: _hasCurrentFile(r)),
              ..._additional.summaries(),
            ]
            .where(
              (r) =>
                  needle.isEmpty ||
                  metadataMatches.contains(r.id) ||
                  [
                    r.id,
                    r.sessionId,
                    r.chatClaim,
                    r.purpose,
                    r.title,
                    r.agentClaim,
                  ].any((s) => s.toLowerCase().contains(needle)),
            )
            .toList();
    final pending = matching
        .where((r) => r.state == WorkspaceApprovalState.pending)
        .length;
    final filtered =
        matching
            .where(
              (r) => switch (query.filter) {
                WorkspaceApprovalFilter.all => true,
                WorkspaceApprovalFilter.pending =>
                  r.state == WorkspaceApprovalState.pending,
                WorkspaceApprovalFilter.done =>
                  r.state != WorkspaceApprovalState.pending,
              },
            )
            .toList()
          ..sort((a, b) {
            final time = b.submittedAt.compareTo(a.submittedAt);
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
      items: filtered.skip(offset).take(query.limit),
      total: filtered.length,
      pending: pending,
      offset: offset,
      selection: index == null ? null : filtered[index].id,
      selectionIndex: index,
    );
  });

  @override
  Future<WorkspaceApprovalDetail> read(String id) => _read(() async {
    if (_additional.contains(id)) return _additional.read(id);
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
    final versions = <core.FieldRef, WorkspaceFileVersion?>{};
    if (!r.historical) {
      for (final ref in refs) {
        final file = records[ref.itemId]?.fields
            .where((f) => f.id == ref.fieldId)
            .firstOrNull
            ?.attachment;
        if (file != null) versions[ref] = await _currentFile(file);
      }
    }
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
            section: item?.name ?? names[ref]?.itemName ?? '已移除资料',
            recordName: item?.name ?? names[ref]?.itemName ?? '已移除资料',
            kind: field?.kind == core.FieldKind.file
                ? WorkspaceApprovalScopeKind.file
                : WorkspaceApprovalScopeKind.field,
            recordVersion: item?.version ?? 0,
            fieldId: ref.fieldId,
            requested: r.fields.contains(ref),
            available:
                field != null &&
                !r.historical &&
                (field.kind != core.FieldKind.file ||
                    owner.informationFileDeliveryAvailable &&
                        versions[ref]?.available == true),
            unavailableReason: field == null
                ? '原字段已不存在。'
                : r.historical
                ? '历史记录不授予访问能力，也不以当前版本冒充原附件。'
                : field.kind == core.FieldKind.file &&
                      !owner.informationFileDeliveryAvailable
                ? '当前运行实例未启用附件领取。'
                : field.kind == core.FieldKind.file &&
                      versions[ref]?.available != true
                ? '当前文件原文不可用，不能批准该文件；可以减选它后审批其他字段。'
                : null,
            fileVersions: versions[ref] == null ? const [] : [versions[ref]!],
          );
        }(),
    ];
    return WorkspaceApprovalDetail(
      request: summaryOf(
        r,
        file: scopes.any((s) => s.kind == WorkspaceApprovalScopeKind.file),
      ),
      reviewToken: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                r.id,
                stateOf(r).name,
                r.decisionPending,
                r.requestExpiresAt.toIso8601String(),
                r.grantExpiresAt?.toIso8601String(),
                for (final s in scopes)
                  [
                    s.id,
                    s.recordVersion,
                    s.available,
                    for (final file in s.fileVersions)
                      [
                        file.ref.toJson(),
                        file.filename,
                        file.mediaType,
                        file.byteLength,
                        file.available,
                      ],
                  ],
              ]),
            ),
          )
          .toString(),
      scopes: scopes,
      approved: (r.approvedFields ?? []).map(key),
      decidedAt: r.approvedAt,
      fieldExpiresAt: r.grantExpiresAt,
      fileVersionPolicy:
          scopes.any((s) => s.kind == WorkspaceApprovalScopeKind.file)
          ? r.historical
                ? '这里是历史决定。原附件版本须以批准时快照或具体交付记录核对，不能以当前附件冒充；历史不会恢复许可。'
                : '核对的是当前附件版本。批准固定字段和期限，之后领取读取该字段当前版本；这里不授予保留旧版本的领取能力。'
          : null,
      decisionUnavailableReason: r.decisionPending
          ? '上次决定仍在保存或结果尚未确认，请先核对原操作。'
          : null,
    );
  });

  WorkspaceApprovalReceipt _receipt(core.InformationApprovalReceipt r) =>
      WorkspaceApprovalReceipt(
        operationId: r.operationId,
        requestId: r.requestId,
        action: WorkspaceApprovalAction.values.byName(r.action.name),
        reviewToken: r.reviewToken,
        revision: r.revision,
        commandDigest: r.commandDigest,
      );

  @override
  Future<WorkspaceApprovalReceipt> change(
    WorkspaceApprovalChange change,
  ) async {
    try {
      return await owner.inLibraryScope(_scope, () async {
        if (_additional.contains(change.requestId) ||
            await _additional.receipt(change.operationId) != null) {
          return _additional.change(change);
        }
        final old = await owner.informationApprovalReceipt(change.operationId);
        if (old != null) {
          if (old.requestId != change.requestId ||
              old.action.name != change.action.name ||
              old.reviewToken != change.reviewToken ||
              old.commandDigest != change.digest) {
            throw const WorkspaceFailure('conflict', '操作编号与原决定不一致，请重新核对。');
          }
          return _receipt(old);
        }
        final current = await read(change.requestId);
        if (current.reviewToken != change.reviewToken) {
          throw const WorkspaceFailure('conflict', '申请或资料已变化，请重新核对范围。');
        }
        if (current.decisionUnavailableReason != null) {
          throw WorkspaceFailure(
            'unknown_outcome',
            current.decisionUnavailableReason!,
          );
        }
        final approving = change.action == WorkspaceApprovalAction.approve;
        if (approving && current.approveUnavailableReason != null) {
          throw WorkspaceFailure(
            'unsupported',
            current.approveUnavailableReason!,
          );
        }
        if (change.selected.toSet().length != change.selected.length ||
            (approving
                ? change.selected.isEmpty ||
                      change.fieldMinutes < 1 ||
                      change.fieldMinutes > 10080
                : change.selected.isNotEmpty ||
                      change.fileVersions.isNotEmpty)) {
          throw const WorkspaceFailure('invalid_scope', '请核对所选字段和使用期限。');
        }
        final scopes = {for (final s in current.scopes) s.id: s};
        if (change.selected.any(
          (id) =>
              scopes[id] == null ||
              !scopes[id]!.available ||
              !scopes[id]!.requested ||
              !{
                WorkspaceApprovalScopeKind.field,
                WorkspaceApprovalScopeKind.file,
              }.contains(scopes[id]!.kind),
        )) {
          throw const WorkspaceFailure('conflict', '所选字段不可用，请重新核对范围。');
        }
        final selectedFiles = change.selected
            .where((id) => scopes[id]!.kind == WorkspaceApprovalScopeKind.file)
            .toList();
        if (change.fileVersions.length != selectedFiles.length ||
            selectedFiles.any(
              (id) =>
                  scopes[id]!.fileVersions.length != 1 ||
                  !scopes[id]!.fileVersions.single.available ||
                  change.fileVersions[id] !=
                      scopes[id]!.fileVersions.single.ref.version,
            )) {
          throw const WorkspaceFailure('conflict', '请选择当前可用文件版本；旧版本或额外文件不能获批。');
        }
        final receipt = await owner.decideInformationRequest(
          core.InformationApprovalCommand(
            operationId: change.operationId,
            requestId: change.requestId,
            action: core.InformationApprovalAction.values.byName(
              change.action.name,
            ),
            reviewToken: change.reviewToken,
            commandDigest: change.digest,
            fields: change.selected.map(
              (id) =>
                  core.FieldRef(scopes[id]!.record.id, scopes[id]!.fieldId!),
            ),
            itemVersions: {
              for (final id in change.selected)
                scopes[id]!.record.id: scopes[id]!.recordVersion,
            },
            expectedFiles: {
              for (final id in selectedFiles)
                core.FieldRef(
                  scopes[id]!.record.id,
                  scopes[id]!.fieldId!,
                ): core.InformationAttachmentRef(
                  scopes[id]!.fileVersions.single.ref.id,
                  change.fileVersions[id]!,
                ),
            },
            lifetime: Duration(minutes: change.fieldMinutes),
          ),
        );
        return _receipt(receipt);
      });
    } on WorkspaceFailure {
      rethrow;
    } on core.AccessFailure catch (e) {
      throw switch (e.status) {
        'request_changed' ||
        'scope_changed' ||
        'invalid_request' ||
        'operation_conflict' => const WorkspaceFailure(
          'conflict',
          '申请、资料或处理结果已变化，请重新核对。',
        ),
        'library_changed' => const WorkspaceFailure(
          'library_changed',
          '资料库已替换，请重新打开收件箱。',
        ),
        'attachment_missing' ||
        'attachment_integrity_failed' => const WorkspaceFailure(
          'file_unavailable',
          '文件原文缺失或校验失败，未批准；请重新核对范围。',
        ),
        'unsupported_capability' => const WorkspaceFailure(
          'unsupported',
          '当前实例未启用文件领取，请重新检查运行版本。',
        ),
        'invalid_scope' || 'invalid_operation' => const WorkspaceFailure(
          'invalid_scope',
          '所选范围或操作无效，请重新核对。',
        ),
        'service_unavailable' => const WorkspaceFailure(
          'unavailable',
          '申请服务不可用，请重新打开收件箱。',
        ),
        _ => const WorkspaceFailure(
          'unknown_outcome',
          '无法确认审批结果，请核对原操作，勿重复提交。',
        ),
      };
    } on FormatException {
      throw const WorkspaceFailure('invalid_scope', '审批范围、操作或期限无效。');
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '无法确认审批结果，请核对原操作，勿重复提交。');
    }
  }

  @override
  Future<WorkspaceApprovalReceipt?> receipt(String operationId) =>
      _read(() async {
        final receipt = await owner.informationApprovalReceipt(operationId);
        final extra = await _additional.receipt(operationId);
        if (receipt != null && extra != null) {
          throw const WorkspaceFailure('unknown_outcome', '原操作存在多种回执，请保留现场。');
        }
        return receipt == null ? extra : _receipt(receipt);
      });
  @override
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) => _read(() => _additional.execution(requestId, operationId));

  @override
  Future<WorkspaceCredentialProgramOperation> programOperation(
    String requestId,
    String operationId,
  ) => _read(
    () async => OwnerWorkspaceCredentialBatches(
      owner,
    ).programOperation(requestId, operationId),
  );
  @override
  Future<WorkspaceCredentialBatchOperation> batchOperation(
    String requestId,
    String operationId,
  ) => _read(
    () async => OwnerWorkspaceCredentialBatches(
      owner,
    ).operation(requestId, operationId),
  );
  @override
  Future<WorkspaceCredentialBatchOperation> acknowledgeBatchOperation(
    WorkspaceCredentialBatchAcknowledgement change,
  ) => _read(() => OwnerWorkspaceCredentialBatches(owner).acknowledge(change));
}
