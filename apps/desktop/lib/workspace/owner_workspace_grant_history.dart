import 'dart:convert';
import 'dart:math';
import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_approvals.dart';
import 'workspace_source.dart';
import 'workspace_information_codec.dart';

/// Ordinary audit facts from the same owner service as approvals. Lists never
/// decode field bodies; snapshot content requires an explicit owner read.
class OwnerWorkspaceGrantHistory implements WorkspaceGrantHistorySource {
  OwnerWorkspaceGrantHistory({required this.owner})
    : _scope = owner.captureLibraryScope(),
      _approvals = OwnerWorkspaceApprovals(owner: owner);
  final core.OwnerAccess owner;
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
    return [
      for (final id in {...requests.keys, ...grants.keys})
        _Entry(requests[id], grants[id], accesses[grants[id]?.id] ?? []),
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
      _ =>
        e.request!.sessionEnded || e.request!.applicationClosed
            ? WorkspaceGrantState.sessionEnded
            : WorkspaceGrantState.unavailable,
    };
  }

  WorkspaceGrantSummary _summary(_Entry e) => WorkspaceGrantSummary(
    id: e.id,
    requestId: e.requestId,
    title: '资料读取申请',
    kind: WorkspaceApprovalKind.information,
    state: _state(e),
    agentClaim: '未提供 Agent 名称',
    chatClaim: e.request?.chatLabel ?? e.grant!.chatLabel,
    purpose: e.request?.purpose ?? '原申请说明已不可用',
    recordedAt: e.at,
    operationCount: e.accesses.length,
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
    final observed = await owner.informationHistory();
    final needle = q.keyword.trim().toLowerCase();
    final cutoff = q.lastDays == null
        ? null
        : observed.observedAt.subtract(Duration(days: q.lastDays!));
    final rows =
        _entries(observed.history)
            .where(
              (e) =>
                  (q.kind == null ||
                      q.kind == WorkspaceApprovalKind.information) &&
                  (cutoff == null || !e.at.isBefore(cutoff)) &&
                  (needle.isEmpty ||
                      [
                        e.requestId,
                        e.request?.sessionId ?? e.grant!.sessionId,
                        e.request?.chatLabel ?? e.grant!.chatLabel,
                        e.request?.purpose ?? '',
                        ...e.fields.expand((f) => [f.itemName, f.fieldName]),
                      ].any((s) => s.toLowerCase().contains(needle))),
            )
            .map(_summary)
            .where(
              (s) => switch (q.filter) {
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
    final audit = await owner.informationHistory();
    final e = _entries(audit.history).where((e) => e.id == id).firstOrNull;
    if (e == null) {
      throw const WorkspaceFailure('not_found', '未找到指定历史或它已按保留规则清理。');
    }
    return e;
  }

  Future<core.InformationItem?> _snapshotItem(_Entry e, String itemId) async {
    final version = e.grant?.itemVersions[itemId];
    if (version == null) return null;
    final revisions = await owner.revisionsFor(itemId);
    final current = owner.information
        .where((i) => i.id == itemId && i.version == version)
        .firstOrNull;
    if (current != null) return current;
    final revision = revisions
        .where((r) => r.item.version == version)
        .firstOrNull;
    if (revision != null) return revision.item;
    return owner.recycleEntries
        .where(
          (r) =>
              r.wholeItem &&
              r.snapshot?.id == itemId &&
              r.snapshot?.version == version,
        )
        .firstOrNull
        ?.snapshot;
  }

  @override
  Future<WorkspaceGrantDetail> read(String id) => _read(() async {
    var e = await _entry(id);
    final targets = <WorkspaceGrantTarget>[];
    for (final itemId in e.fields.map((f) => f.itemId).toSet()) {
      final f = e.fields.firstWhere((f) => f.itemId == itemId);
      targets.add(
        WorkspaceGrantTarget(
          record: WorkspaceRecordRef(WorkspaceRecordKind.information, itemId),
          name: f.itemName,
          version: e.grant?.itemVersions[itemId] ?? 0,
          exists: owner.information.any((i) => i.id == itemId),
          snapshotAvailable: await _snapshotItem(e, itemId) != null,
        ),
      );
    }
    // Lookup can await retention; compute live state only after those reads.
    WorkspaceApprovalDetail? approval;
    try {
      approval = await _approvals.read(e.requestId);
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
                owner.information
                        .where((i) => i.id == f.itemId)
                        .firstOrNull
                        ?.fields
                        .where((field) => field.id == f.fieldId)
                        .firstOrNull
                        ?.kind ==
                    core.FieldKind.file
                ? WorkspaceApprovalScopeKind.file
                : WorkspaceApprovalScopeKind.field,
            active: _active(g, f),
            expiresAt: g.expiresAt,
          ),
      ],
      events: events,
      reviewToken: approval?.reviewToken,
      decidedAt: e.at,
      fieldExpiresAt: g?.expiresAt,
      legacyNotice: g?.restoredAt != null
          ? '这是恢复的历史事实，不代表当前可用授权。'
          : g != null && g.itemVersions.isEmpty
          ? '旧授权没有记录批准时的资料版本，不能提供当时快照。'
          : e.request == null
          ? '原申请记录已清理，仅保留授权与访问事实。'
          : null,
    );
  });

  @override
  Future<WorkspaceArchive> snapshot(String id, WorkspaceRecordRef record) =>
      _read(() async {
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

  @override
  Future<WorkspaceFilePreview> filePreview(
    String id,
    String scopeId, {
    int page = 0,
  }) => _read(() async {
    await _entry(id);
    throw const WorkspaceFailure('unsupported', '普通附件历史预览尚未接入。');
  });
}

class _Entry {
  _Entry(this.request, this.grant, this.accesses);
  final core.RequestHistory? request;
  final core.GrantHistory? grant;
  final List<core.AccessRecord> accesses;
  String get requestId => request?.id ?? grant!.requestId;
  String get id => 'request:$requestId';
  DateTime get at => grant?.approvedAt ?? request!.recordedAt;
  List<core.RecordedField> get fields => grant?.fields ?? request!.fields;
}
