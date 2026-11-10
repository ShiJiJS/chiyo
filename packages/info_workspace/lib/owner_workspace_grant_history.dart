import 'dart:convert';
import 'dart:math';
import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_approvals.dart';
import 'owner_workspace_additional_approvals.dart';
import 'owner_credential_use_projection.dart';
import 'workspace_source.dart';
import 'workspace_information_codec.dart';

part 'owner_workspace_additional_grant_history.dart';

/// Unified audit facts from the same owner service as approvals. Lists never
/// decode field bodies; snapshot content requires an explicit owner read.
class OwnerWorkspaceGrantHistory implements WorkspaceGrantHistorySource {
  OwnerWorkspaceGrantHistory({required this.owner, this.filePreviewRenderer})
    : _scope = owner.captureLibraryScope(),
      _approvals = OwnerWorkspaceApprovals(owner: owner);
  final core.OwnerAccess owner;
  final Future<WorkspaceFilePreview> Function(
    core.InformationAttachmentRef ref,
    core.InformationFileDelivery? original,
    int page,
  )?
  filePreviewRenderer;
  final core.OwnerLibraryScope _scope;
  final OwnerWorkspaceApprovals _approvals;
  final _codec = WorkspaceInformationCodec();

  Future<T> _read<T>(Future<T> Function() read) async {
    try {
      return await owner.inLibraryScope(_scope, read);
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, switch (e.status) {
        'library_changed' => '资料库已替换，请重新打开授权历史。',
        'audit_unavailable' => '访问记录暂时无法确认，请稍后重试。',
        _ => '历史服务暂时不可用，请稍后重试。',
      });
    }
  }

  List<_Entry> _entries(core.AuditHistory audit) {
    final requests = {for (final r in audit.requests) r.id: r};
    final grants = {for (final g in audit.grants) g.requestId: g};
    final accesses = <String, List<core.AccessRecord>>{};
    for (final access in audit.accesses) {
      if (access.grantId case final id?) {
        accesses.putIfAbsent(id, () => []).add(access);
      }
    }
    final deliveries = <String, List<core.InformationFileDelivery>>{};
    for (final d in owner.informationFileDeliveries) {
      final grant = grants[d.requestId];
      if (grant != null &&
          grant.id == d.grantId &&
          grant.fields.any(
            (f) => f.itemId == d.field.itemId && f.fieldId == d.field.fieldId,
          )) {
        deliveries.putIfAbsent(d.requestId, () => []).add(d);
      }
    }
    return [
      for (final id in {...requests.keys, ...grants.keys})
        _Entry(
          requests[id],
          grants[id],
          accesses[grants[id]?.id] ?? [],
          deliveries[id] ?? [],
        ),
    ];
  }

  bool _active(core.GrantHistory g, core.RecordedField f) =>
      owner.canReadGrantedField(g, core.FieldRef(f.itemId, f.fieldId));

  WorkspaceGrantState _state(_Entry e) {
    final g = e.grant;
    if (g != null) {
      if (g.restoredAt != null) return WorkspaceGrantState.unavailable;
      final active = g.fields.where((f) => _active(g, f)).length;
      if (active > 0) {
        return active == g.fields.length
            ? WorkspaceGrantState.active
            : WorkspaceGrantState.partial;
      }
      return switch (g.events.last.kind) {
        core.GrantEventKind.revoked => WorkspaceGrantState.revoked,
        core.GrantEventKind.expired => WorkspaceGrantState.expired,
        core.GrantEventKind.ended || core.GrantEventKind.applicationClosed =>
          WorkspaceGrantState.sessionEnded,
        core.GrantEventKind.approved => WorkspaceGrantState.unavailable,
      };
    }
    return switch (e.request!.state) {
      core.AccessRequestState.denied => WorkspaceGrantState.denied,
      core.AccessRequestState.expired => WorkspaceGrantState.expired,
      core.AccessRequestState.revoked => WorkspaceGrantState.revoked,
      core.AccessRequestState.cancelled => WorkspaceGrantState.cancelled,
      _ =>
        e.request!.sessionEnded || e.request!.applicationClosed
            ? WorkspaceGrantState.sessionEnded
            : WorkspaceGrantState.unavailable,
    };
  }

  bool _hasFile(_Entry e) =>
      e.deliveries.isNotEmpty ||
      e.fields.any((f) {
        final item = e.grant?.itemVersions.containsKey(f.itemId) == true
            ? _recordedItem(e, f.itemId)
            : owner.information.where((i) => i.id == f.itemId).firstOrNull;
        return item?.fields.any(
              (v) => v.id == f.fieldId && v.kind == core.FieldKind.file,
            ) ==
            true;
      });

  WorkspaceGrantSummary _summary(_Entry e) => WorkspaceGrantSummary(
    id: e.id,
    requestId: e.requestId,
    title: _hasFile(e) ? '文件与字段申请' : '资料读取申请',
    kind: _hasFile(e)
        ? WorkspaceApprovalKind.file
        : WorkspaceApprovalKind.information,
    state: _state(e),
    agentClaim: e.request?.agentName ?? e.grant!.agentName,
    chatClaim: core.submissionChatLabel(
      e.request?.chatLabel ?? e.grant!.chatLabel,
      e.request?.externalChatId ?? e.grant!.externalChatId,
    ),
    purpose:
        e.request?.purpose ??
        (e.grant!.purpose.isEmpty ? '原申请说明已不可用' : e.grant!.purpose),
    recordedAt: e.at,
    operationCount: e.accesses.length + e.deliveries.length,
  );

  @override
  Future<WorkspaceGrantResults> query(
    WorkspaceGrantQuery q, {
    String? keepSelection,
  }) => _read(() async {
    if (q.offset < 0 ||
        q.offset > 1000000 ||
        q.limit < 1 ||
        q.limit > 100 ||
        q.keyword.length > 2000 ||
        (q.lastDays != null && ![1, 7, 30].contains(q.lastDays))) {
      throw const WorkspaceFailure('invalid_query', '授权历史查询条件无效。');
    }
    final observed = await owner.informationHistory(
      includeCredentialFields: true,
    );
    final needle = q.keyword.trim().toLowerCase();
    final cutoff = q.lastDays == null
        ? null
        : observed.observedAt.subtract(Duration(days: q.lastDays!));
    final ordinary = _entries(observed.history);
    final additionalIds = {
      for (final r in owner.credentialUseRequests) r.id,
      for (final t in owner.organizationTasks) t.id,
    };
    final rows =
        <WorkspaceGrantSummary>[
              for (final e in ordinary)
                if (!additionalIds.contains(e.requestId)) _summary(e),
              ..._additionalSummaries(ordinary),
            ]
            .where(
              (s) =>
                  (q.kind == null || q.kind == s.kind) &&
                  (cutoff == null || !s.recordedAt.isBefore(cutoff)) &&
                  (needle.isEmpty ||
                      _historySearch(
                        s,
                        ordinary,
                      ).any((v) => v.toLowerCase().contains(needle))) &&
                  switch (q.filter) {
                    WorkspaceGrantFilter.all => true,
                    WorkspaceGrantFilter.active => s.state.isActive,
                    WorkspaceGrantFilter.ended => !s.state.isActive,
                  },
            )
            .toList()
          ..sort((a, b) {
            final time = b.recordedAt.compareTo(a.recordedAt);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
    final offset = rows.isEmpty
        ? 0
        : min(q.offset, (rows.length - 1) ~/ q.limit * q.limit);
    final kept = rows.indexWhere((r) => r.id == keepSelection);
    final index = rows.isEmpty
        ? null
        : kept >= 0
        ? kept
        : offset;
    return WorkspaceGrantResults(
      items: rows.skip(offset).take(q.limit),
      total: rows.length,
      offset: offset,
      selection: index == null ? null : rows[index].id,
      selectionIndex: index,
    );
  });

  Future<_Entry> _entry(String id) async {
    final audit = await owner.informationHistory(includeCredentialFields: true);
    final e = _entries(audit.history).where((e) => e.id == id).firstOrNull;
    if (e == null) {
      throw const WorkspaceFailure('not_found', '未找到指定历史或它已按保留规则清理。');
    }
    return e;
  }

  core.InformationItem? _recordedItem(_Entry e, String itemId) {
    final version = e.grant?.itemVersions[itemId];
    if (version == null) return null;
    return _recordedVersion(itemId, version);
  }

  core.InformationItem? _recordedVersion(String itemId, int version) {
    return owner.information
            .where((i) => i.id == itemId && i.version == version)
            .firstOrNull ??
        owner.informationRevisions
            .where((r) => r.item.id == itemId && r.item.version == version)
            .firstOrNull
            ?.item ??
        owner.recycleEntries
            .where(
              (r) =>
                  r.wholeItem &&
                  r.snapshot?.id == itemId &&
                  r.snapshot?.version == version,
            )
            .firstOrNull
            ?.snapshot;
  }

  Future<core.InformationItem?> _snapshotItem(_Entry e, String itemId) async {
    if (e.grant?.itemVersions[itemId] == null) return null;
    await owner.revisionsFor(itemId);
    return _recordedItem(e, itemId);
  }

  @override
  Future<WorkspaceGrantDetail> read(String id) => _read(() async {
    if (_additionalRequest(id)) return _readAdditionalHistory(id);
    return _readInformationHistory(id);
  });

  Future<WorkspaceGrantDetail> _readInformationHistory(
    String id, {
    bool linkDecision = true,
  }) async {
    var e = await _entry(id);
    final targets = <WorkspaceGrantTarget>[];
    final snapshots = <String, core.InformationItem?>{};
    for (final itemId in e.fields.map((f) => f.itemId).toSet()) {
      final f = e.fields.firstWhere((f) => f.itemId == itemId);
      snapshots[itemId] = await _snapshotItem(e, itemId);
      targets.add(
        WorkspaceGrantTarget(
          record: WorkspaceRecordRef(WorkspaceRecordKind.information, itemId),
          name: f.itemName,
          version: e.grant?.itemVersions[itemId] ?? 0,
          exists: owner.information.any((i) => i.id == itemId),
          snapshotAvailable: snapshots[itemId] != null,
        ),
      );
    }
    // Lookup can await retention; compute live state only after those reads.
    WorkspaceApprovalDetail? approval;
    try {
      if (linkDecision) approval = await _approvals.read(e.requestId);
    } on WorkspaceFailure catch (error) {
      if (error.code != 'not_found') rethrow;
    }
    e = await _entry(id);
    final g = e.grant;
    final events =
        <WorkspaceGrantEvent>[
          if (g != null)
            for (var i = 0; i < g.events.length; i++)
              WorkspaceGrantEvent(
                'grant:${g.id}:$i',
                g.events[i].at,
                '授权状态变化',
                switch (g.events[i].kind) {
                  core.GrantEventKind.approved => '已批准；不代表已经读取',
                  core.GrantEventKind.revoked => '主人已撤销',
                  core.GrantEventKind.expired => '固定期限已到',
                  core.GrantEventKind.ended => '会话已结束',
                  core.GrantEventKind.applicationClosed => '应用服务已关闭',
                },
              ),
          if (g == null)
            WorkspaceGrantEvent(
              'request:${e.requestId}',
              e.at,
              '申请处理结果',
              switch (e.request!.state) {
                core.AccessRequestState.denied => '主人已拒绝',
                core.AccessRequestState.expired => '申请已过期',
                core.AccessRequestState.cancelled => '申请已取消',
                _ => '原授权记录已不可用',
              },
            ),
          for (final d in e.deliveries)
            WorkspaceGrantEvent(
              'delivery:${d.id}',
              d.createdAt,
              '文件交付 · ${d.field.itemName} · ${d.field.fieldName} · ${d.fileName} · 附件v${d.attachment.attachmentVersion}',
              '${_deliveryState(d)}；${d.mediaType} · ${d.byteLength}字节。交付不代表上传完成，路径移除不能收回已读取内容。',
              fileScopeId: 'delivery:${d.id}',
              fileRecord: WorkspaceRecordRef(
                WorkspaceRecordKind.information,
                d.field.itemId,
              ),
              fileVersion: d.attachment.attachmentVersion,
            ),
          for (final a in e.accesses)
            WorkspaceGrantEvent(
              'access:${a.id}',
              a.at,
              '读取 ${a.itemName ?? '原资料'} · ${a.fieldName ?? '原字段'}',
              switch (a.outcome) {
                core.AccessOutcome.allowed => '已允许读取',
                core.AccessOutcome.unauthorized => '已拒绝：不在当前有效授权内',
                core.AccessOutcome.auditUnavailable => '未交付：审计不可用',
                core.AccessOutcome.fileDeliveryRequired => '未交付：需通过附件领取流程',
              },
            ),
        ]..sort((a, b) {
          final t = b.at.compareTo(a.at);
          return t == 0 ? a.id.compareTo(b.id) : t;
        });
    return WorkspaceGrantDetail(
      summary: _summary(e),
      targets: targets,
      scopes: [
        for (final f in g?.fields ?? const <core.RecordedField>[])
          WorkspaceGrantedScope(
            id: jsonEncode([f.itemId, f.fieldId]),
            record: WorkspaceRecordRef(
              WorkspaceRecordKind.information,
              f.itemId,
            ),
            label: f.fieldName,
            recordVersion: g!.itemVersions[f.itemId] ?? 0,
            kind:
                snapshots[f.itemId]?.fields
                            .where((field) => field.id == f.fieldId)
                            .firstOrNull
                            ?.kind ==
                        core.FieldKind.file ||
                    e.deliveries.any(
                      (d) =>
                          d.field.itemId == f.itemId &&
                          d.field.fieldId == f.fieldId,
                    )
                ? WorkspaceApprovalScopeKind.file
                : WorkspaceApprovalScopeKind.field,
            fileVersion: snapshots[f.itemId]?.fields
                .where((field) => field.id == f.fieldId)
                .firstOrNull
                ?.attachment
                ?.attachmentVersion,
            active: _active(g, f),
            expiresAt: g.expiresAt,
          ),
      ],
      events: events,
      reviewToken: approval?.reviewToken,
      decidedAt: e.at,
      fieldExpiresAt: g?.expiresAt,
      scopeNotice:
          '批准成员和期限固定；有效期内读取这些字段的当前内容。下列批准附件版本仅是当时核对快照，不锁定后续领取版本；每次实际交付版本另见事件。',
      legacyNotice: g?.restoredAt != null
          ? '这是恢复的历史事实，不代表当前可用授权。'
          : g != null && g.itemVersions.isEmpty
          ? '旧授权没有记录批准时的资料版本，不能提供当时快照。'
          : e.request == null
          ? '原申请记录已清理，仅保留授权与访问事实。'
          : null,
    );
  }

  @override
  Future<WorkspaceArchive> snapshot(String id, WorkspaceRecordRef record) =>
      _read(() async {
        final organization = _organizationHistory(id);
        if (organization != null) {
          if (record.kind != WorkspaceRecordKind.information ||
              organization.approvedAt == null ||
              !organization.itemVersions.containsKey(record.id)) {
            throw const WorkspaceFailure('not_found', '此资料不属于指定批准范围。');
          }
          final version = organization.itemVersions[record.id]!;
          await owner.revisionsFor(record.id);
          final fresh = _organizationHistory(id);
          if (fresh == null || fresh.itemVersions[record.id] != version) {
            throw const WorkspaceFailure('not_found', '指定整理历史已变化或清理。');
          }
          final item = _recordedVersion(record.id, version);
          if (item == null) {
            throw const WorkspaceFailure(
              'snapshot_unavailable',
              '当时的资料快照已不可用。',
            );
          }
          return WorkspaceArchive(
            detail: _codec.decode(
              item,
              tagNames: {for (final t in owner.tags) t.id: t.name},
            ),
            archivedAt: organization.approvedAt!,
          );
        }
        final e = await _entry(id);
        if (record.kind != WorkspaceRecordKind.information ||
            !e.fields.any((f) => f.itemId == record.id)) {
          throw const WorkspaceFailure('not_found', '此资料不属于指定历史。');
        }
        final item = await _snapshotItem(e, record.id);
        if (item == null) {
          throw const WorkspaceFailure('snapshot_unavailable', '当时的资料快照已不可用。');
        }
        return WorkspaceArchive(
          detail: _codec.decode(
            item,
            tagNames: {for (final t in owner.tags) t.id: t.name},
          ),
          archivedAt: e.grant!.approvedAt,
        );
      });

  Future<
    ({
      core.InformationAttachmentRef ref,
      core.InformationFileDelivery? original,
    })
  >
  resolveFile(String id, String scopeId, {int page = 0}) => _read(() async {
    final e = await _entry(id);
    core.InformationAttachmentRef? ref;
    core.InformationFileDelivery? delivered;
    if (scopeId.startsWith('delivery:')) {
      final d = e.deliveries
          .where((d) => 'delivery:${d.id}' == scopeId)
          .firstOrNull;
      if (d == null) throw const WorkspaceFailure('not_found', '此交付不属于指定历史。');
      ref = d.attachment;
      delivered = d;
    } else {
      final f = e.grant?.fields
          .where((f) => jsonEncode([f.itemId, f.fieldId]) == scopeId)
          .firstOrNull;
      if (f == null) throw const WorkspaceFailure('not_found', '此字段不属于指定批准范围。');
      final item = await _snapshotItem(e, f.itemId);
      ref = item?.fields
          .where((v) => v.id == f.fieldId)
          .firstOrNull
          ?.attachment;
      if (ref == null) {
        throw const WorkspaceFailure(
          'snapshot_unavailable',
          '批准时的准确附件快照已不可用，不会替换成当前文件。',
        );
      }
    }
    return (ref: ref, original: delivered);
  });

  @override
  Future<WorkspaceFilePreview> filePreview(
    String id,
    String scopeId, {
    int page = 0,
  }) => _read(() async {
    final file = await resolveFile(id, scopeId, page: page);
    final render = filePreviewRenderer;
    if (render == null) {
      throw const WorkspaceFailure('unsupported', '文件预览需要由使用设备展示。');
    }
    return render(file.ref, file.original, page);
  });

  String _deliveryState(core.InformationFileDelivery d) {
    final state = switch (d.state) {
      'preparing' => '正在准备，尚未确认交付',
      'ready' => '受管副本已准备，不代表Agent已经读取',
      'released' => '登记副本路径已移除',
      'expired' => '副本已失效，登记副本路径已移除',
      'cleanup_pending' => '待清理，不能认作已回收',
      'failed' => '交付失败',
      _ => '交付结果未知',
    };
    final reason = switch (d.reason) {
      'released' => 'Agent结束使用',
      'grant_expired' => '授权已到期',
      'not_authorized' => '授权已撤销或失效',
      'session_ended' => '会话已结束',
      'field_removed' => '原字段已移除',
      'restarted' => '应用已重开',
      'service_closed' => '应用服务已关闭',
      'attachment_integrity_failed' => '原文校验失败',
      'audit_failed' => '事实存储未确认',
      'delivery_io_failed' => '文件交付失败',
      'delivery_unknown' => '未确认交付结果',
      _ => null,
    };
    final cleanup = switch (d.cleanupError) {
      'cleanup_identity_mismatch' => '登记副本身份变化，未删除替换对象',
      'cleanup_failed' => '副本清理失败',
      _ => null,
    };
    return [
      state,
      ?reason,
      ?cleanup,
      if (!d.runtime || d.restoredAt != null) '仅历史事实，不恢复受管副本或授权',
    ].join('；');
  }
}

class _Entry {
  _Entry(this.request, this.grant, this.accesses, this.deliveries);
  final core.RequestHistory? request;
  final core.GrantHistory? grant;
  final List<core.AccessRecord> accesses;
  final List<core.InformationFileDelivery> deliveries;
  String get requestId => request?.id ?? grant!.requestId;
  String get id => 'request:$requestId';
  DateTime get at => grant?.approvedAt ?? request!.recordedAt;
  List<core.RecordedField> get fields => grant?.fields ?? request!.fields;
}
