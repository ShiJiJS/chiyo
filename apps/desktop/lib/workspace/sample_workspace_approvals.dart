part of 'sample_workspace_source.dart';

class _ApprovalInput {
  _ApprovalInput(
    this.id,
    this.title,
    this.kind,
    this.purpose,
    this.at,
    this.session,
    this.targets, {
    this.credential,
    this.requestedKeys = const {},
    this.additional = true,
    DateTime? requestExpiresAt,
  }) : requestExpiresAt =
           requestExpiresAt ?? at.add(const Duration(minutes: 15));
  final String id, title, purpose;
  final WorkspaceApprovalKind kind;
  final DateTime at;
  final DateTime requestExpiresAt;
  final WorkspaceCredentialSession session;
  final List<WorkspaceRecordRef> targets;
  final WorkspaceCredentialUseRequest? credential;
  final Set<String> requestedKeys;
  final bool additional;
  Map<String, WorkspaceApprovalScope> original = {};
}

class _ApprovalFact {
  _ApprovalFact(
    this.action,
    this.scopes,
    this.files,
    this.at,
    this.fieldEnd,
    this.credentialEnd,
    this.revision,
  );
  final WorkspaceApprovalAction action;
  final Map<String, WorkspaceApprovalScope> scopes;
  final Map<String, int> files;
  final DateTime at;
  final DateTime? fieldEnd, credentialEnd;
  final int revision;
}

/// One canonical synthetic decision store. Credential pages project it too.
class _SampleApprovals implements WorkspaceApprovalSource {
  _SampleApprovals(this.s);
  final SampleWorkspaceSource s;
  final _inputs = <String, _ApprovalInput>{},
      _dynamic = <String, _ApprovalInput>{};
  final _facts = <String, _ApprovalFact>{};
  final _receipts =
      <String, ({String fingerprint, WorkspaceApprovalReceipt receipt})>{};
  final _ended = <String>{};
  final _pruned = <String>{};
  final _restored = <String>{};
  final _organizationFinished = <String>{};
  final _executions = <String, Map<String, WorkspaceApprovalExecution>>{};
  WorkspaceFailure? nextExecutionReadFailure;
  bool _seeded = false;
  int _generation = 0, _revision = 0;
  Duration _offset = Duration.zero;
  bool loseNextReply = false;
  DateTime get now => s._now().add(_offset);
  WorkspaceRecordRef info(String id) =>
      WorkspaceRecordRef(WorkspaceRecordKind.information, id);
  WorkspaceRecordRef secret(String id) =>
      WorkspaceRecordRef(WorkspaceRecordKind.credential, id);
  String hash(Object? v) =>
      sha256.convert(utf8.encode(jsonEncode(v))).toString();

  WorkspaceCredentialUseRequest _seedCredential(
    String id,
    String ref,
    String purpose,
    DateTime at,
  ) {
    final d = s._credentials.currentMetadata(secret(ref));
    final receivers = s._credentials.receiverFacts(d.record.ref);
    return WorkspaceCredentialUseRequest(
      id: id,
      approvalReference: id,
      ref: d.record.ref,
      credentialName: d.record.name,
      materialVersion: d.materialVersion,
      useGeneration: d.useGeneration,
      delivery: d.delivery,
      receiver: id == 'token'
          ? WorkspaceCredentialReceiver(
              id: 'github-read',
              label: 'GitHub 仓库查看',
              executable: '/usr/bin/gh',
              workingDirectory: '/example/maintenance',
              arguments: const ['repo', 'view', 'northstar/agent-skills'],
              binding: d.binding,
            )
          : id == 'server' && receivers.isNotEmpty
          ? WorkspaceCredentialReceiver(
              id: receivers.first.id,
              label: receivers.first.label,
              executable: receivers.first.executable,
              workingDirectory: receivers.first.workingDirectory,
              arguments: [
                ...receivers.first.arguments,
                'systemctl status caddy',
              ],
              binding: receivers.first.binding,
            )
          : receivers.firstOrNull ??
                WorkspaceCredentialReceiver(
                  id: 'focus-disabled',
                  label: '本机焦点填充',
                  executable: '',
                  workingDirectory: '',
                  arguments: const [],
                  binding: '本机前台输入焦点',
                ),
      session: const WorkspaceCredentialSession(
        'session-maintenance',
        '当前维护会话',
        'Codex',
      ),
      purpose: purpose,
      minutes: 15,
      submittedAt: at,
    );
  }

  void _seed() {
    if (_seeded) return;
    _seeded = true;
    const session = WorkspaceCredentialSession(
      'session-maintenance',
      '当前维护会话',
      'Codex',
    );
    final rows =
        <
          ({
            String id,
            String title,
            WorkspaceApprovalKind kind,
            String purpose,
            List<String> records,
            String? credential,
            Set<String> fields,
          })
        >[
          (
            id: 'server',
            title: '检查反向代理服务',
            kind: WorkspaceApprovalKind.credential,
            purpose: '检查 Caddy 状态，核对站点入口及证书配置。',
            records: ['azure'],
            credential: 'sshkey',
            fields: {'azure:host', 'azure:user', 'azure:port'},
          ),
          (
            id: 'resume',
            title: '填写招聘网站资料',
            kind: WorkspaceApprovalKind.file,
            purpose: '读取选用的简历，并在申请职位时上传。',
            records: ['resume', 'profile'],
            credential: null,
            fields: {'resume:file', 'profile:email'},
          ),
          (
            id: 'token',
            title: '查看项目仓库',
            kind: WorkspaceApprovalKind.credential,
            purpose: '查看仓库状态和待处理事项。',
            records: [],
            credential: 'github-token',
            fields: {},
          ),
          (
            id: 'fill',
            title: '登录任务管理',
            kind: WorkspaceApprovalKind.focus,
            purpose: '在已打开的任务管理登录页填入密码。',
            records: [],
            credential: 'vikunja-password',
            fields: {},
          ),
          (
            id: 'organize',
            title: '整理自托管服务资料',
            kind: WorkspaceApprovalKind.organization,
            purpose: '按用途整理目录，补充环境与应用用途标签。',
            records: ['blinko', 'vikunja', 'sparky'],
            credential: null,
            fields: {},
          ),
        ];
    for (final (i, row) in rows.take(s._basePending).indexed) {
      final at = now.subtract(Duration(minutes: i + 1));
      WorkspaceCredentialUseRequest? credential;
      if (row.credential != null) {
        try {
          credential = _seedCredential(
            row.id,
            row.credential!,
            row.purpose,
            at,
          );
        } on WorkspaceFailure {
          /* Missing fixture objects remain unavailable. */
        }
      }
      final raw = _ApprovalInput(
        row.id,
        row.title,
        row.kind,
        row.purpose,
        at,
        session,
        row.records.map(info).toList(),
        credential: credential,
        requestedKeys: row.fields,
        additional: row.kind != WorkspaceApprovalKind.credential,
      );
      _inputs[raw.id] = raw;
      raw.original = {for (final scope in _liveScopes(raw)) scope.id: scope};
    }
  }

  List<_ApprovalInput> _all() {
    _seed();
    for (final r in s._credentials.requestFacts) {
      final id = 'credential:${r.id}';
      if (_pruned.contains(id)) continue;
      if (!_dynamic.containsKey(id)) {
        final raw = _ApprovalInput(
          id,
          '使用${r.credentialName}',
          WorkspaceApprovalKind.credential,
          r.purpose,
          r.submittedAt,
          r.session,
          [],
          credential: r,
          additional: false,
          requestExpiresAt: r.requestExpiresAt,
        );
        _dynamic[id] = raw;
        raw.original = {for (final scope in _liveScopes(raw)) scope.id: scope};
      }
    }
    return [
      ..._inputs.values,
      ..._dynamic.values,
    ].where((r) => !_pruned.contains(r.id)).toList();
  }

  _ApprovalInput _input(String id) =>
      _all().where((r) => r.id == id).firstOrNull ??
      (throw const WorkspaceFailure('not_found', '请求已不存在，请重新读取收件箱。'));

  Iterable<WorkspaceApprovalScope> _liveScopes(_ApprovalInput raw) sync* {
    for (final ref in raw.targets) {
      final d = s._records[ref];
      if (d == null) continue;
      if (raw.kind == WorkspaceApprovalKind.organization) {
        yield WorkspaceApprovalScope(
          id: 'organization:${ref.key}',
          record: ref,
          label: d.record.name,
          section: '目录与标签',
          recordName: d.record.name,
          kind: WorkspaceApprovalScopeKind.organization,
          recordVersion: d.version,
          requested: true,
        );
        continue;
      }
      for (final f in workspaceFields(d)) {
        final key = f['key'] as String,
            type = f['type'],
            label = f['label'] as String;
        final requested =
            raw.requestedKeys.contains('${ref.id}:$key') ||
            raw.original.values.any(
              (x) =>
                  x.record == ref &&
                  x.requested &&
                  x.fieldId == d.fieldIds[key],
            );
        if (!raw.additional && !requested) continue;
        if (type == 'entries') {
          try {
            for (final (i, e) in WorkspaceRepeatedEntry.read(
              d.values[key],
            ).indexed) {
              for (final part in e.activeParts) {
                yield WorkspaceApprovalScope(
                  id: 'field:${ref.key}:${e.fieldIds[part]}',
                  record: ref,
                  label: e.label(part) == WorkspaceRepeatedEntry.labels[part]
                      ? const {
                          'title': '名称',
                          'period': '时间',
                          'detail': '说明',
                        }[part]!
                      : e.label(part),
                  section: '${d.record.name} · $label ${i + 1}',
                  recordName: d.record.name,
                  kind: WorkspaceApprovalScopeKind.field,
                  recordVersion: d.version,
                  fieldKey: key,
                  fieldId: e.fieldIds[part],
                  entryId: e.id,
                  requested: requested,
                );
              }
            }
          } on FormatException {
            /* Never offer a whole malformed JSON as a grant field. */
          }
        } else if (d.fieldIds[key] case final fieldId?) {
          if (type == 'unknown') continue;
          yield WorkspaceApprovalScope(
            id: 'field:${ref.key}:$fieldId',
            record: ref,
            label: label,
            section: d.record.name,
            recordName: d.record.name,
            kind: type == 'file'
                ? WorkspaceApprovalScopeKind.file
                : WorkspaceApprovalScopeKind.field,
            recordVersion: d.version,
            fieldKey: key,
            fieldId: fieldId,
            requested: requested,
          );
        }
      }
    }
    if (raw.credential case final r?) {
      var available = true;
      String? reason;
      try {
        final d = s._credentials.currentMetadata(r.ref);
        if (!d.enabled ||
            d.materialVersion != r.materialVersion ||
            d.useGeneration != r.useGeneration ||
            d.delivery != r.delivery ||
            (d.binding.isNotEmpty && d.binding != r.receiver.binding)) {
          available = false;
          reason = '凭据材料、启用状态或使用配置已变化。';
        } else if (!d.useSupported) {
          available = false;
          reason = d.unavailableReason;
        }
      } on WorkspaceFailure {
        available = false;
        reason = '凭据已不可用。';
      }
      yield WorkspaceApprovalScope(
        id: 'use:${r.ref.key}:${r.materialVersion}:${r.useGeneration}',
        record: r.ref,
        label: '${r.credentialName} · 材料v${r.materialVersion}',
        section: '凭据使用',
        recordName: r.credentialName,
        kind: WorkspaceApprovalScopeKind.credential,
        recordVersion: s._records[r.ref]?.version ?? 0,
        requested: true,
        available: available,
        unavailableReason: reason,
      );
    }
  }

  List<WorkspaceApprovalScope> _scopes(_ApprovalInput raw) {
    final live = {for (final x in _liveScopes(raw)) x.id: x},
        fact = _facts[raw.id];
    return [
      for (final x in live.values)
        x.project(
          requested: raw.original[x.id]?.requested ?? false,
          available:
              x.available && (fact == null || fact.scopes.containsKey(x.id)),
          files: fact?.scopes[x.id]?.fileVersions,
        ),
      for (final x in {...raw.original, ...?fact?.scopes}.values)
        if (!live.containsKey(x.id))
          x.project(available: false, reason: '原字段或资料已删除，不能按同名重新关联。'),
    ];
  }

  bool _active(_ApprovalInput r, WorkspaceApprovalScope x, _ApprovalFact f) {
    if (f.action != WorkspaceApprovalAction.approve ||
        _organizationFinished.contains(r.id) ||
        _ended.contains(r.session.id) ||
        !x.available ||
        !f.scopes.containsKey(x.id)) {
      return false;
    }
    final end = x.kind == WorkspaceApprovalScopeKind.credential
        ? f.credentialEnd
        : f.fieldEnd;
    if (end == null || !now.isBefore(end)) return false;
    if (x.kind == WorkspaceApprovalScopeKind.organization &&
        x.recordVersion != f.scopes[x.id]!.recordVersion) {
      return false;
    }
    if (x.kind == WorkspaceApprovalScopeKind.file) {
      final d = s._records[x.record];
      if (d == null ||
          !s._files.retainsVersion(d, x.fieldKey!, f.files[x.id] ?? -1)) {
        return false;
      }
    }
    return true;
  }

  WorkspaceApprovalState _state(_ApprovalInput r) {
    if (_organizationFinished.contains(r.id)) {
      return WorkspaceApprovalState.completed;
    }
    final f = _facts[r.id];
    if (f?.action == WorkspaceApprovalAction.deny) {
      return WorkspaceApprovalState.denied;
    }
    if (f?.action == WorkspaceApprovalAction.revoke) {
      return WorkspaceApprovalState.revoked;
    }
    if (_ended.contains(r.session.id)) {
      return WorkspaceApprovalState.sessionEnded;
    }
    if (f == null) {
      if (!now.isBefore(r.requestExpiresAt)) {
        return WorkspaceApprovalState.expired;
      }
      final scopes = _scopes(r);
      if (scopes.isEmpty ||
          r.kind != WorkspaceApprovalKind.focus &&
              !scopes.any((x) => x.available) ||
          r.credential != null &&
              r.kind != WorkspaceApprovalKind.focus &&
              !scopes.any(
                (x) =>
                    x.kind == WorkspaceApprovalScopeKind.credential &&
                    x.available,
              )) {
        return WorkspaceApprovalState.unavailable;
      }
      return WorkspaceApprovalState.pending;
    }
    if (_scopes(r).any((x) => _active(r, x, f))) {
      return WorkspaceApprovalState.approved;
    }
    if ([
      f.fieldEnd,
      f.credentialEnd,
    ].whereType<DateTime>().every((e) => !now.isBefore(e))) {
      return WorkspaceApprovalState.expired;
    }
    return WorkspaceApprovalState.unavailable;
  }

  WorkspaceApprovalSummary _summary(_ApprovalInput r) =>
      WorkspaceApprovalSummary(
        id: r.id,
        title: r.title,
        kind: r.kind,
        agentClaim: r.session.agentClaim,
        sessionId: r.session.id,
        chatClaim: r.session.label,
        purpose: r.purpose,
        submittedAt: r.at,
        requestExpiresAt: r.requestExpiresAt,
        state: _state(r),
      );
  String _stamp(_ApprovalInput r) => hash({
    'epoch': s._epoch,
    'generation': _generation,
    'request': r.id,
    'requestExpiresAt': r.requestExpiresAt.toIso8601String(),
    'fact': _facts[r.id]?.revision,
    'state': _state(r).name,
    'scope': [
      for (final x in _scopes(r)) [x.id, x.recordVersion, x.available],
    ],
  });
  int get pendingCount =>
      _all().where((r) => _state(r) == WorkspaceApprovalState.pending).length;

  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery q, {
    String? keepSelection,
  }) async {
    await s._readable();
    if (q.limit < 1 ||
        q.limit > 100 ||
        q.offset < 0 ||
        q.keyword.length > 1000) {
      throw const WorkspaceFailure('invalid_query', '请核对搜索与分页范围。');
    }
    final all = s._scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceApprovalSummary>[]
        : _all().map(_summary).toList();
    final found =
        all
            .where(
              (r) =>
                  (q.filter == WorkspaceApprovalFilter.all ||
                      (q.filter == WorkspaceApprovalFilter.pending) ==
                          (r.state == WorkspaceApprovalState.pending)) &&
                  '${r.title} ${r.agentClaim} ${r.chatClaim} ${r.purpose} ${r.kind.label}'
                      .toLowerCase()
                      .contains(q.keyword.trim().toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final t = b.submittedAt.compareTo(a.submittedAt);
            return t != 0 ? t : a.id.compareTo(b.id);
          });
    final offset = found.isEmpty
        ? 0
        : q.offset.clamp(0, (found.length - 1) ~/ q.limit * q.limit);
    final selection = found.any((r) => r.id == keepSelection)
        ? keepSelection
        : found.skip(offset).firstOrNull?.id;
    return WorkspaceApprovalResults(
      items: found.skip(offset).take(q.limit),
      total: found.length,
      pending: all
          .where((r) => r.state == WorkspaceApprovalState.pending)
          .length,
      offset: offset,
      selection: selection,
      selectionIndex: selection == null
          ? null
          : found.indexWhere((r) => r.id == selection),
    );
  }

  @override
  Future<WorkspaceApprovalDetail> read(String id) async {
    await s._readable();
    if (s._scenario == SampleWorkspaceScenario.empty) {
      throw const WorkspaceFailure('not_found', '请求已不存在。');
    }
    final r = _input(id),
        stamp = _stamp(r),
        f = _facts[id],
        scopes = <WorkspaceApprovalScope>[];
    for (final rawScope in _scopes(r)) {
      final x = f != null
          ? rawScope.project(
              available: _active(r, rawScope, f),
              reason: !rawScope.available
                  ? rawScope.unavailableReason
                  : _active(r, rawScope, f)
                  ? null
                  : '此范围已到期或失效。',
            )
          : rawScope;
      if (x.kind == WorkspaceApprovalScopeKind.file && x.available) {
        try {
          final h = await s.loadFileHistory(x.record, x.fieldKey!);
          scopes.add(x.project(files: h.versions));
        } on WorkspaceFailure catch (e) {
          if (e.code != 'not_found') rethrow;
          scopes.add(x.project(available: false, reason: '附件版本已不可用。'));
        }
      } else {
        scopes.add(x);
      }
    }
    if (stamp != _stamp(r)) {
      throw const WorkspaceFailure('conflict', '请求范围已变化，请重新读取。');
    }
    return WorkspaceApprovalDetail(
      request: _summary(r),
      reviewToken: stamp,
      scopes: scopes,
      credential: r.credential,
      executions: _executions[id]?.values ?? const [],
      approved: f?.scopes.keys ?? const [],
      fileVersions: f?.files ?? const {},
      decidedAt: f?.at,
      fieldExpiresAt: f?.fieldEnd,
      credentialExpiresAt: f?.credentialEnd,
      approveUnavailableReason: r.kind == WorkspaceApprovalKind.focus
          ? '当前预览不执行实际密码填写。'
          : null,
    );
  }

  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange c) async {
    await s._readable();
    final fingerprint = c.digest;
    WorkspaceApprovalReceipt? replay() {
      final old = _receipts[c.operationId];
      if (old == null) return null;
      if (old.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同次操作不能用于不同审批内容。');
      }
      return old.receipt;
    }

    if (replay() case final receipt?) return receipt;
    final epoch = s._epoch,
        detail = await read(c.requestId),
        r = _input(c.requestId);
    if (replay() case final receipt?) return receipt;
    if (s._disposed ||
        epoch != s._epoch ||
        c.reviewToken != detail.reviewToken ||
        c.reviewToken != _stamp(r)) {
      throw const WorkspaceFailure('conflict', '请求或范围已变化，请重新读取并核对。');
    }
    if (c.operationId.isEmpty) {
      throw const WorkspaceFailure('validation', '审批操作身份不能为空。');
    }
    final state = detail.request.state;
    final selected = {
      for (final x in detail.scopes)
        if (c.selected.contains(x.id)) x.id: x,
    };
    if (c.action == WorkspaceApprovalAction.revoke) {
      if (state != WorkspaceApprovalState.approved) {
        throw const WorkspaceFailure('conflict', '本次授权已失效，请重新读取。');
      }
    } else if (state != WorkspaceApprovalState.pending) {
      throw const WorkspaceFailure('conflict', '请求已处理或结束，请重新读取。');
    }
    if (c.action == WorkspaceApprovalAction.approve) {
      if (!detail.canApprove) {
        throw WorkspaceFailure(
          'unsupported',
          detail.approveUnavailableReason ?? '没有可批准的范围。',
        );
      }
      if (selected.isEmpty ||
          selected.length > 200 ||
          selected.length != c.selected.length ||
          selected.values.any((x) => !x.available)) {
        throw const WorkspaceFailure('validation', '请选择1–200个当前可用且不重复的范围。');
      }
      if (![
            15,
            30,
            60,
            ...AccessTiming.grantMinutes,
          ].contains(c.fieldMinutes) ||
          ![
            15,
            30,
            ...AccessTiming.grantMinutes,
          ].contains(c.credentialMinutes) ||
          r.kind == WorkspaceApprovalKind.organization &&
              c.fieldMinutes > 30 &&
              !AccessTiming.grantMinutes.contains(c.fieldMinutes)) {
        throw const WorkspaceFailure('validation', '请核对普通范围、凭据与整理的独立期限。');
      }
      final files = selected.values
          .where((x) => x.kind == WorkspaceApprovalScopeKind.file)
          .toList();
      if (c.fileVersions.length != files.length ||
          files.any(
            (x) => !x.fileVersions.any(
              (v) => v.ref.version == c.fileVersions[x.id],
            ),
          )) {
        throw const WorkspaceFailure('validation', '请为每个普通附件选择准确的现存版本。');
      }
    }
    s._beforeApprovalWrite();
    final old = _facts[r.id], at = now;
    _facts[r.id] = _ApprovalFact(
      c.action,
      c.action == WorkspaceApprovalAction.approve
          ? Map.unmodifiable(selected)
          : old?.scopes ?? const {},
      c.action == WorkspaceApprovalAction.approve
          ? Map.unmodifiable(c.fileVersions)
          : old?.files ?? const {},
      c.action == WorkspaceApprovalAction.revoke ? old!.at : at,
      c.action == WorkspaceApprovalAction.approve
          ? (selected.values.any(
                  (x) => x.kind != WorkspaceApprovalScopeKind.credential,
                )
                ? at.add(Duration(minutes: c.fieldMinutes))
                : null)
          : old?.fieldEnd,
      c.action == WorkspaceApprovalAction.approve
          ? (selected.values.any(
                  (x) => x.kind == WorkspaceApprovalScopeKind.credential,
                )
                ? at.add(Duration(minutes: c.credentialMinutes!))
                : null)
          : old?.credentialEnd,
      ++_revision,
    );
    final receipt = WorkspaceApprovalReceipt(
      operationId: c.operationId,
      requestId: r.id,
      action: c.action,
      reviewToken: c.reviewToken,
      revision: _revision,
      commandDigest: c.digest,
    );
    _receipts[c.operationId] = (fingerprint: fingerprint, receipt: receipt);
    s._changes.add(null);
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure('unknown_outcome', '审批结果暂时未知，请先核对本次操作。');
    }
    return receipt;
  }

  @override
  Future<WorkspaceApprovalReceipt?> receipt(String id) async {
    await s._readable();
    return _receipts[id]?.receipt;
  }

  Iterable<WorkspaceCredentialUseRequest> seedCredentialRequests(
    WorkspaceRecordRef? ref,
  ) {
    _seed();
    return [
      for (final raw in _inputs.values)
        if (raw.credential != null &&
            (ref == null || raw.credential!.ref == ref))
          raw.credential!,
    ];
  }

  WorkspaceCredentialRequestState credentialState(
    WorkspaceCredentialUseRequest r,
  ) {
    if (r.state != WorkspaceCredentialRequestState.pending) return r.state;
    final raw = _all().where((x) => x.id == r.approvalId).firstOrNull;
    if (raw == null) return r.state;
    final fact = _facts[raw.id];
    if (fact?.action == WorkspaceApprovalAction.approve &&
        fact!.scopes.values.any(
          (x) => x.kind == WorkspaceApprovalScopeKind.credential,
        ) &&
        !now.isBefore(fact.credentialEnd!)) {
      return WorkspaceCredentialRequestState.expired;
    }
    return switch (_state(raw)) {
      WorkspaceApprovalState.pending => WorkspaceCredentialRequestState.pending,
      WorkspaceApprovalState.approved =>
        _facts[raw.id]!.scopes.values.any(
              (x) => x.kind == WorkspaceApprovalScopeKind.credential,
            )
            ? WorkspaceCredentialRequestState.approved
            : WorkspaceCredentialRequestState.partiallyApproved,
      WorkspaceApprovalState.denied => WorkspaceCredentialRequestState.denied,
      WorkspaceApprovalState.revoked => WorkspaceCredentialRequestState.revoked,
      WorkspaceApprovalState.expired => WorkspaceCredentialRequestState.expired,
      WorkspaceApprovalState.sessionEnded =>
        WorkspaceCredentialRequestState.sessionEnded,
      WorkspaceApprovalState.unavailable =>
        WorkspaceCredentialRequestState.superseded,
      WorkspaceApprovalState.cancelled =>
        WorkspaceCredentialRequestState.superseded,
      WorkspaceApprovalState.completed =>
        WorkspaceCredentialRequestState.superseded,
      WorkspaceApprovalState.proposed || WorkspaceApprovalState.conflicted =>
        WorkspaceCredentialRequestState.unavailable,
    };
  }

  Iterable<WorkspaceCredentialUseHistory> credentialHistory(
    WorkspaceRecordRef ref,
  ) sync* {
    for (final r in _all()) {
      final f = _facts[r.id];
      if (r.credential?.ref != ref ||
          f == null ||
          !f.scopes.values.any(
            (x) => x.kind == WorkspaceApprovalScopeKind.credential,
          )) {
        continue;
      }
      yield WorkspaceCredentialUseHistory(
        grantId: 'preview-grant:${r.id}',
        credentialName: r.credential!.credentialName,
        materialVersion: r.credential!.materialVersion,
        delivery: r.credential!.delivery,
        session: r.session,
        purpose: r.purpose,
        expiresAt: f.credentialEnd!,
        state: f.action == WorkspaceApprovalAction.revoke
            ? '已撤销'
            : _ended.contains(r.session.id)
            ? '会话已结束'
            : !now.isBefore(f.credentialEnd!)
            ? '已到期'
            : _scopes(r).any(
                (x) =>
                    x.kind == WorkspaceApprovalScopeKind.credential &&
                    x.available,
              )
            ? '有效'
            : '凭据已失效',
        operations: [
          for (final e
              in _executions[r.id]?.values ?? <WorkspaceApprovalExecution>[])
            WorkspaceCredentialUseOperation(
              e.operationId,
              e.createdAt,
              e.plan.label,
              e.resultLabel,
            ),
        ],
      );
    }
  }

  @override
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) async {
    await s._readable();
    if (nextExecutionReadFailure case final error?) {
      nextExecutionReadFailure = null;
      throw error;
    }
    if (s._scenario == SampleWorkspaceScenario.empty) {
      throw const WorkspaceFailure('not_found', '原使用记录不可读取，不能推断它没有执行。');
    }
    return _executions[requestId]?[operationId] ??
        (throw const WorkspaceFailure('not_found', '原使用记录不可读取，不能推断它没有执行。'));
  }

  // Preview composition only. This records fictional observations, without
  // process, file, material, runtime capability or production service access.
  void demonstrateExecutions(String id) {
    final r = _input(id), f = _facts[id];
    if (r.credential == null ||
        r.kind == WorkspaceApprovalKind.focus ||
        f?.action != WorkspaceApprovalAction.approve ||
        _state(r) != WorkspaceApprovalState.approved ||
        !_scopes(r).any(
          (x) =>
              x.kind == WorkspaceApprovalScopeKind.credential &&
              _active(r, x, f!),
        )) {
      throw const WorkspaceFailure('unavailable', '请先批准仍有效的凭据范围，再显示使用记录。');
    }
    if (_executions.containsKey(id)) return;
    final credential = r.credential!,
        rows = <String, WorkspaceApprovalExecution>{};
    for (final (index, state) in [
      WorkspaceExecutionState.exited,
      WorkspaceExecutionState.startFailed,
      WorkspaceExecutionState.unknown,
    ].indexed) {
      final plan = WorkspaceCredentialReceiver(
        id: credential.receiver.id,
        label: ['核对连接状态', '查询服务状态', '核对后续状态'][index],
        executable: credential.receiver.executable,
        workingDirectory: credential.receiver.workingDirectory,
        arguments: [...credential.receiver.arguments],
        binding: credential.receiver.binding,
      );
      final operation = WorkspaceApprovalExecution(
        requestId: id,
        grantId: 'preview-grant:$id',
        operationId: 'preview-use:$id:${index + 1}',
        credential: credential,
        plan: plan,
        createdAt: now,
        state: state,
        revision: 1,
        processStarted: state != WorkspaceExecutionState.startFailed,
        processEnded: state != WorkspaceExecutionState.unknown,
        exitCode: state == WorkspaceExecutionState.exited ? 0 : null,
        errorCode: state == WorkspaceExecutionState.startFailed
            ? 'process_start_failed'
            : state == WorkspaceExecutionState.unknown
            ? 'execution_unknown'
            : null,
        cleanup: credential.delivery == WorkspaceCredentialDelivery.file
            ? (state == WorkspaceExecutionState.unknown
                  ? WorkspaceExecutionCleanup.needsCheck
                  : WorkspaceExecutionCleanup.complete)
            : WorkspaceExecutionCleanup.notNeeded,
      );
      rows[operation.operationId] = operation;
    }
    _executions[id] = rows;
    s._changes.add(null);
  }

  void publishExecutionObservation(String id) {
    final rows = _executions[id];
    if (_restored.contains(id)) return;
    if (rows == null) return;
    for (final e in rows.values.toList()) {
      if (e.state != WorkspaceExecutionState.unknown || e.processEnded) {
        continue;
      }
      rows[e.operationId] = e.observed(
        at: now,
        revision: e.revision + 1,
        processEnded: true,
        cleanup: e.cleanup == WorkspaceExecutionCleanup.notNeeded
            ? e.cleanup
            : WorkspaceExecutionCleanup.complete,
      );
    }
    // Simulate a host observation available to the next explicit status read.
    // No UI event, launch/replay, success inference or grant deadline change.
  }

  void advance(Duration d) {
    if (d < Duration.zero) throw ArgumentError.value(d);
    _all();
    _offset += d;
    s._changes.add(null);
  }

  void endSession(String id) {
    _ended.add(id);
    s._changes.add(null);
  }

  void reset() {
    _inputs.clear();
    _dynamic.clear();
    _facts.clear();
    _receipts.clear();
    _ended.clear();
    _pruned.clear();
    _restored.clear();
    _organizationFinished.clear();
    _executions.clear();
    nextExecutionReadFailure = null;
    _seeded = false;
    _offset = Duration.zero;
    _generation++;
    _revision = 0;
    loseNextReply = false;
  }
}
