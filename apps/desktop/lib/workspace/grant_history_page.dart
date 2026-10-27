import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import 'approval_executions.dart';
import 'grant_history_controller.dart';
import 'grant_history_dialog.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

class GrantHistoryPage extends StatefulWidget {
  const GrantHistoryPage({
    super.key,
    required this.controller,
    required this.onRecord,
    required this.onRequest,
    this.onModalChanged,
    this.onRetry,
  });
  final GrantHistoryController controller;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final ValueChanged<String> onRequest;
  final ValueChanged<bool>? onModalChanged;
  final VoidCallback? onRetry;
  @override
  State<GrantHistoryPage> createState() => _GrantHistoryPageState();
}

class _GrantHistoryPageState extends State<GrantHistoryPage> {
  GrantHistoryController get m => widget.controller;
  final _search = TextEditingController();
  late ScrollController _list, _detail;
  String? _selection;
  String _queryKey = '';
  WorkspaceGrantState? _state;
  @override
  void initState() {
    super.initState();
    _selection = m.selection;
    _state = m.detail?.summary.state;
    _search.text = m.keyword;
    _queryKey =
        '${m.keyword}/${m.filter.name}/${m.kind?.name}/${m.lastDays}/${m.offset}/${m.limit}';
    _list = ScrollController(initialScrollOffset: m.listScroll)
      ..addListener(() => m.listScroll = _list.offset);
    _detail = ScrollController(initialScrollOffset: m.detailScroll)
      ..addListener(() => m.detailScroll = _detail.offset);
    m.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    final key =
        '${m.keyword}/${m.filter.name}/${m.kind?.name}/${m.lastDays}/${m.offset}/${m.limit}';
    if (_queryKey != key) {
      _queryKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _list.hasClients) _list.jumpTo(0);
      });
    }
    final state = m.detail?.summary.state;
    if (_selection != m.selection ||
        state != null && _state != null && state != _state) {
      _selection = m.selection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detail.hasClients) _detail.jumpTo(0);
      });
    }
    if (state != null) _state = state;
    if (_search.text != m.keyword && !_search.value.composing.isValid) {
      _search.text = m.keyword;
    }
    setState(() {});
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    _search.dispose();
    _list.dispose();
    _detail.dispose();
    super.dispose();
  }

  Color _color(BuildContext context, WorkspaceGrantState state) =>
      state == WorkspaceGrantState.active
      ? UiPalette.of(context).success
      : state == WorkspaceGrantState.partial
      ? UiPalette.of(context).warning
      : UiPalette.of(context).muted;
  Future<void> _content(
    WorkspaceGrantTarget target, {
    String? scopeId,
    int? fileVersion,
  }) async {
    if (m.frozen || m.detail == null) return;
    final id = m.detail!.summary.id;
    widget.onModalChanged?.call(true);
    try {
      await showDesktopDialog<void>(
        context,
        builder: (_) => GrantHistoryContentDialog(
          source: m.source,
          changes: m.changes,
          historyId: id,
          record: target.record,
          label: scopeId == null
              ? '${target.name} · 当时资料v${target.version}'
              : '${target.name} · 批准附件v$fileVersion',
          scopeId: scopeId,
        ),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Widget _header(BuildContext context, bool large) {
    final c = UiPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '授权历史',
            style: libraryText(context, 26, weight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (!large)
            Text(
              '查看批准范围、重复使用与结束原因',
              style: libraryText(context, 14, color: c.muted, height: 1.8),
            ),
          const SizedBox(height: 20),
          DesktopTextField(
            key: const ValueKey('grant-history-search'),
            controller: _search,
            enabled: !m.frozen,
            onChanged: m.search,
            decoration: const InputDecoration(labelText: '搜索请求与用途'),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in WorkspaceGrantFilter.values)
                DesktopButton(
                  key: ValueKey('grant-filter-${f.name}'),
                  selected: m.filter == f,
                  kind: DesktopButtonKind.quiet,
                  onPressed: m.frozen ? null : () => m.setFilter(f),
                  child: Text(switch (f) {
                    WorkspaceGrantFilter.all => '全部',
                    WorkspaceGrantFilter.active => '有效',
                    WorkspaceGrantFilter.ended => '已结束',
                  }),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: large ? 190 : 220,
                child: DesktopSelect<String>(
                  key: const ValueKey('grant-kind'),
                  value: m.kind?.name ?? 'all',
                  items: [
                    const DropdownMenuItem(value: 'all', child: Text('所有类型')),
                    for (final k in WorkspaceApprovalKind.values)
                      DropdownMenuItem(value: k.name, child: Text(k.label)),
                  ],
                  onChanged: m.frozen
                      ? null
                      : (v) => m.setKind(
                          v == 'all'
                              ? null
                              : WorkspaceApprovalKind.values.byName(v!),
                        ),
                ),
              ),
              SizedBox(
                width: large ? 190 : 180,
                child: DesktopSelect<int>(
                  key: const ValueKey('grant-days'),
                  value: m.lastDays ?? 0,
                  items: [
                    for (final day in [0, 1, 7, 30])
                      DropdownMenuItem(
                        value: day,
                        child: Text(day == 0 ? '所有时间' : '最近$day天'),
                      ),
                  ],
                  onChanged: m.frozen
                      ? null
                      : (v) => m.setDays(v == 0 ? null : v),
                ),
              ),
            ],
          ),
          if (m.notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                m.notice!,
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _listPane(BuildContext context, bool large) {
    final c = UiPalette.of(context), r = m.results;
    final heading = <Widget>[
      _header(context, large),
      if (m.loading) const LinearProgressIndicator(),
      if (m.readFailure != null)
        Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.readFailure!.message,
                style: libraryText(context, 14, color: c.danger),
              ),
              DesktopButton(
                key: const ValueKey('grant-retry'),
                onPressed: m.frozen
                    ? null
                    : widget.onRetry ?? () => m.load(review: true),
                child: const Text('重新读取'),
              ),
            ],
          ),
        ),
    ];
    final empty = Padding(
      padding: const EdgeInsets.all(28),
      child: Text(
        m.loading || r == null
            ? '正在读取授权历史…'
            : m.readFailure != null
            ? '历史读取失败，请重试。'
            : '没有匹配的授权记录。',
        style: libraryText(context, 14, color: c.muted),
      ),
    );
    if (large) {
      // At large text sizes and in the narrow stacked layout, filters must
      // scroll too so they cannot consume the list's entire available height.
      return ListView(
        key: const ValueKey('grant-history-list'),
        controller: _list,
        children: [
          ...heading,
          if (r == null || r.items.isEmpty)
            empty
          else
            for (final h in r.items) _row(context, h, true),
          if (r != null) _pager(context, r),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...heading,
        Expanded(
          child: r == null || r.items.isEmpty
              ? Center(child: empty)
              : ListView.builder(
                  key: const ValueKey('grant-history-list'),
                  controller: _list,
                  itemCount: r.items.length,
                  itemBuilder: (context, index) =>
                      _row(context, r.items[index], false),
                ),
        ),
        if (r != null) _pager(context, r),
      ],
    );
  }

  Widget _row(BuildContext context, WorkspaceGrantSummary h, bool large) {
    final c = UiPalette.of(context);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(h.title, style: libraryText(context, 15, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          '${h.kind.label} · ${h.agentClaim}',
          style: libraryText(context, 12, color: c.muted, height: 1.7),
        ),
      ],
    );
    final status = Text(
      h.state.label,
      style: libraryText(context, 13, color: _color(context, h.state)),
    );
    final date = Text(
      libraryLocalDateTime(h.recordedAt),
      style: libraryText(context, 12, color: c.muted),
    );
    return DesktopButton(
      key: ValueKey('grant-row-${h.id}'),
      kind: DesktopButtonKind.quiet,
      selected: m.selection == h.id,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
      onPressed: m.frozen ? null : () => m.select(h.id),
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [title, const SizedBox(height: 8), status, date],
            )
          : Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 15),
                SizedBox(width: 95, child: status),
                const SizedBox(width: 15),
                SizedBox(width: 135, child: date),
              ],
            ),
    );
  }

  Widget _pager(BuildContext context, WorkspaceGrantResults r) {
    final c = UiPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          Text(
            '${r.total} 条记录',
            style: libraryText(context, 13, color: c.muted),
          ),
          Wrap(
            spacing: 8,
            children: [
              DesktopButton(
                key: const ValueKey('grant-prev'),
                onPressed: m.frozen || r.offset == 0
                    ? null
                    : () => m.page((r.offset - m.limit).clamp(0, r.total)),
                child: const Text('上一页'),
              ),
              DesktopButton(
                key: const ValueKey('grant-next'),
                onPressed: m.frozen || r.offset + m.limit >= r.total
                    ? null
                    : () => m.page(r.offset + m.limit),
                child: const Text('下一页'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(top: 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: libraryText(context, 16, weight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      );
  Widget _detailPane(BuildContext context) {
    final d = m.detail, c = UiPalette.of(context);
    if (d == null) {
      return Center(
        child: Text(
          m.reading ? '正在读取记录…' : '选择一条授权记录',
          style: libraryText(context, 14, color: c.muted),
        ),
      );
    }
    final h = d.summary;
    return SingleChildScrollView(
      key: const ValueKey('grant-history-detail-scroll'),
      controller: _detail,
      padding: const EdgeInsets.fromLTRB(25, 30, 25, 28),
      child: DesktopEntrance(
        key: ValueKey(h.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              h.state.label,
              style: libraryText(
                context,
                13,
                color: _color(context, h.state),
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              h.title,
              style: libraryText(context, 24, weight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              '${h.agentClaim} · ${h.chatClaim}',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
            Text(
              '名称和用途为Agent自述。',
              style: libraryText(context, 12, color: c.muted),
            ),
            const SizedBox(height: 10),
            Text(h.purpose, style: libraryText(context, 14, height: 1.9)),
            if (d.fieldExpiresAt != null)
              Text(
                '普通范围至 ${libraryLocalDateTime(d.fieldExpiresAt!)}',
                style: libraryText(context, 13, color: c.muted, height: 1.8),
              ),
            if (d.credentialExpiresAt != null)
              Text(
                '凭据至 ${libraryLocalDateTime(d.credentialExpiresAt!)}',
                style: libraryText(context, 13, color: c.muted, height: 1.8),
              ),
            _section(context, '批准范围', [
              if (d.scopes.isEmpty)
                Text(
                  '本次没有批准任何范围。',
                  style: libraryText(context, 14, color: c.muted),
                ),
              for (final scope in d.scopes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '• ${scope.label}${scope.fileVersion == null ? '' : ' · 附件v${scope.fileVersion}'}',
                        style: libraryText(context, 14, height: 1.8),
                      ),
                      Text(
                        scope.active ? '仍有效' : '已结束或失效',
                        style: libraryText(
                          context,
                          12,
                          color: scope.active ? c.success : c.muted,
                        ),
                      ),
                      if (scope.kind == WorkspaceApprovalScopeKind.file)
                        DesktopButton(
                          key: ValueKey('grant-file-${scope.id}'),
                          kind: DesktopButtonKind.quiet,
                          onPressed: m.frozen || m.loading || m.reading
                              ? null
                              : () => _content(
                                  d.targets.firstWhere(
                                    (t) => t.record == scope.record,
                                  ),
                                  scopeId: scope.id,
                                  fileVersion: scope.fileVersion,
                                ),
                          child: Text('查看批准的附件v${scope.fileVersion}'),
                        ),
                    ],
                  ),
                ),
              if (d.scopes.any(
                (s) => s.kind == WorkspaceApprovalScopeKind.field,
              ))
                Text(
                  '批准成员固定；有效期内读取这些字段的最新内容。附件版本另外固定。',
                  style: libraryText(context, 12, color: c.muted, height: 1.8),
                ),
            ]),
            if (m.linkedDecision &&
                m.decision.detail!.credentialExpiresAt != null)
              ApprovalExecutions(controller: m.decision),
            if (d.events.isNotEmpty)
              _section(context, '访问与使用事件', [
                for (final e in d.events)
                  Container(
                    padding: const EdgeInsets.only(left: 17, bottom: 20),
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: c.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          libraryLocalDateTime(e.at),
                          style: libraryText(context, 12, color: c.muted),
                        ),
                        Text(
                          e.description,
                          style: libraryText(context, 14, height: 1.9),
                        ),
                        Text(
                          e.result,
                          style: libraryText(context, 13, color: c.muted),
                        ),
                      ],
                    ),
                  ),
              ])
            else if (h.operationCount == 0)
              _section(context, '访问与使用事件', [
                Text(
                  '尚无访问或使用记录；批准不等于已经读取或执行。',
                  style: libraryText(context, 13, color: c.muted, height: 1.9),
                ),
              ]),
            if (d.legacyNotice != null)
              Text(
                d.legacyNotice!,
                style: libraryText(context, 12, color: c.muted, height: 1.8),
              ),
            _section(context, '关联资料', [
              for (final t in d.targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        t.name,
                        style: libraryText(
                          context,
                          14,
                          weight: FontWeight.w600,
                        ),
                      ),
                      if (!t.exists)
                        Text(
                          '当前对象已删除或不可用。历史名称与身份仍保留。',
                          style: libraryText(
                            context,
                            13,
                            color: c.muted,
                            height: 1.8,
                          ),
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          DesktopButton(
                            key: ValueKey('grant-current-${t.record.key}'),
                            kind: DesktopButtonKind.quiet,
                            onPressed: m.frozen || !t.exists
                                ? null
                                : () => widget.onRecord(t.record),
                            child: const Text('查看当前资料'),
                          ),
                          if (t.record.kind == WorkspaceRecordKind.information)
                            DesktopButton(
                              key: ValueKey('grant-snapshot-${t.record.key}'),
                              kind: DesktopButtonKind.quiet,
                              onPressed: m.frozen || !t.snapshotAvailable
                                  ? null
                                  : () => _content(t),
                              child: Text('查看当时资料v${t.version}'),
                            ),
                        ],
                      ),
                      if (t.record.kind == WorkspaceRecordKind.information &&
                          !t.snapshotAvailable)
                        Text(
                          '当时的资料快照已不可用。',
                          style: libraryText(context, 12, color: c.muted),
                        ),
                    ],
                  ),
                ),
            ]),
            if (h.requestId != null)
              DesktopButton(
                key: const ValueKey('grant-request'),
                kind: DesktopButtonKind.quiet,
                onPressed: m.frozen
                    ? null
                    : () => widget.onRequest(h.requestId!),
                child: const Text('查看原审批请求'),
              ),
            if (d.canRevoke)
              DesktopButton(
                key: const ValueKey('grant-revoke'),
                onPressed: m.canRevoke ? m.revoke : null,
                child: const Text('撤销本次请求全部范围'),
              ),
            if (m.linkedDecision && m.decision.notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  m.decision.notice!,
                  style: libraryText(context, 13, color: c.muted, height: 1.8),
                ),
              ),
            if (m.decisionFailure != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  m.decisionFailure!.message,
                  style: libraryText(context, 13, color: c.danger, height: 1.8),
                ),
              ),
            if (m.decision.uncertain)
              DesktopButton(
                key: const ValueKey('grant-reconcile'),
                onPressed: m.decision.busy ? null : m.reconcile,
                child: const Text('核对本次撤销'),
              ),
            const SizedBox(height: 12),
            DesktopButton(
              key: const ValueKey('grant-refresh'),
              kind: DesktopButtonKind.quiet,
              onPressed: m.frozen ? null : () => m.load(review: true),
              child: const Text('重新读取记录'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final c = UiPalette.of(context),
          large = MediaQuery.textScalerOf(context).scale(14) > 20;
      final right = large
          ? (bounds.maxWidth - 460).clamp(380.0, bounds.maxWidth)
          : MediaQuery.sizeOf(context).width <= 1300
          ? 335.0
          : 365.0;
      final list = _listPane(context, large || bounds.maxWidth < 900),
          detail = Container(
            decoration: BoxDecoration(
              color: c.rail,
              border: Border(left: BorderSide(color: c.line)),
            ),
            child: _detailPane(context),
          );
      return bounds.maxWidth < 900
          ? Column(
              children: [
                SizedBox(height: 360, child: list),
                Expanded(child: detail),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: list),
                SizedBox(width: right, child: detail),
              ],
            );
    },
  );
}
