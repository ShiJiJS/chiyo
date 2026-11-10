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
    this.onProposal,
    this.onWorkspaceBack,
    this.workspaceBackLabel = '返回上一页',
  });
  final GrantHistoryController controller;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final ValueChanged<String> onRequest;
  final ValueChanged<bool>? onModalChanged;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onProposal;
  final VoidCallback? onWorkspaceBack;
  final String workspaceBackLabel;
  @override
  State<GrantHistoryPage> createState() => _GrantHistoryPageState();
}

class _GrantHistoryPageState extends State<GrantHistoryPage> {
  GrantHistoryController get m => widget.controller;
  final _search = TextEditingController();
  late ScrollController _list, _detail;
  String? _selection;
  String _queryKey = '';
  bool _filters = false;
  final _expandedSnapshots = <String>{};
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
    String? contentLabel,
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
          label:
              contentLabel ??
              (scopeId == null
                  ? '${target.name} · 审批时的内容'
                  : '${target.name} · 批准附件v$fileVersion'),
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
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('授权历史', style: libraryHeading(context, 24))),
              IconButton(
                tooltip: _filters ? '收起筛选' : '筛选记录',
                isSelected: _filters,
                onPressed: () => setState(() => _filters = !_filters),
                icon: const Icon(Icons.tune, size: 19),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DesktopTextField(
            key: const ValueKey('grant-history-search'),
            controller: _search,
            enabled: !m.frozen,
            onChanged: m.search,
            decoration: const InputDecoration(
              hintText: '搜索申请或用途',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in WorkspaceGrantFilter.values)
                DesktopButton(
                  key: ValueKey('grant-filter-${f.name}'),
                  selected: m.filter == f,
                  kind: DesktopButtonKind.quiet,
                  onPressed: m.frozen ? null : () => m.setFilter(f),
                  minimumSize: const Size(0, 32),
                  child: Text(switch (f) {
                    WorkspaceGrantFilter.all => '全部',
                    WorkspaceGrantFilter.active => '有效',
                    WorkspaceGrantFilter.ended => '已结束',
                  }),
                ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: !_filters
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      children: [
                        DesktopSelect<String>(
                          key: const ValueKey('grant-kind'),
                          value: m.kind?.name ?? 'all',
                          items: [
                            const DropdownMenuItem(
                              value: 'all',
                              child: Text('所有类型'),
                            ),
                            for (final k in WorkspaceApprovalKind.values)
                              DropdownMenuItem(
                                value: k.name,
                                child: Text(k.label),
                              ),
                          ],
                          onChanged: m.frozen
                              ? null
                              : (v) => m.setKind(
                                  v == 'all'
                                      ? null
                                      : WorkspaceApprovalKind.values.byName(v!),
                                ),
                        ),
                        const SizedBox(height: 8),
                        DesktopSelect<int>(
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
                      ],
                    ),
                  ),
          ),
          if (widget.onWorkspaceBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: m.frozen ? null : widget.onWorkspaceBack,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: Text(widget.workspaceBackLabel),
              ),
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
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: ListView.builder(
                    key: const ValueKey('grant-history-list'),
                    controller: _list,
                    itemCount: r.items.length,
                    itemBuilder: (context, index) =>
                        _row(context, r.items[index], false),
                  ),
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
        Text(
          h.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: libraryText(context, 14, weight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          [h.kind.label, h.agentClaim].where((v) => v.isNotEmpty).join(' · '),
          style: libraryText(context, 12, color: c.muted, height: 1.7),
        ),
      ],
    );
    final status = Align(
      alignment: Alignment.centerLeft,
      child: LibraryPill(
        h.state.label,
        color: _color(context, h.state),
        background: h.state == WorkspaceGrantState.active
            ? c.successSurface
            : c.nav,
      ),
    );
    final date = Text(
      libraryLocalDateTime(h.recordedAt),
      style: libraryText(context, 12, color: c.muted),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: DesktopButton(
        key: ValueKey('grant-row-${h.id}'),
        kind: DesktopButtonKind.quiet,
        selected: m.selection == h.id,
        alignment: Alignment.centerLeft,
        radius: 5,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        onPressed: m.frozen ? null : () => m.select(h.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            title,
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [status, date],
            ),
          ],
        ),
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
        padding: const EdgeInsets.only(top: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: libraryText(context, 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
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
            Align(
              alignment: Alignment.centerLeft,
              child: LibraryPill(
                h.state.label,
                color: _color(context, h.state),
                background: h.state == WorkspaceGrantState.active
                    ? c.successSurface
                    : c.nav,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              h.title,
              style: libraryText(
                context,
                21,
                weight: FontWeight.w700,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              [
                h.agentClaim,
                h.chatClaim,
              ].where((v) => v.isNotEmpty).join(' · '),
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
            const SizedBox(height: 10),
            Text(h.purpose, style: libraryText(context, 14, height: 1.9)),
            if (d.fieldExpiresAt != null)
              Text(
                '普通范围至 ${libraryLocalDateTime(d.fieldExpiresAt!)}',
                style: libraryText(context, 13, color: c.muted, height: 1.8),
              ),
            if (d.credentialSessionBound)
              Text(
                '凭据：不限时（限本聊天）',
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
                  '本次没有批准任何资料。',
                  style: libraryText(context, 14, color: c.muted),
                ),
              for (final scope in d.scopes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (d.scopes
                              .firstWhere((s) => s.record == scope.record)
                              .id ==
                          scope.id)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            d.targets
                                    .where((t) => t.record == scope.record)
                                    .firstOrNull
                                    ?.name ??
                                '关联资料',
                            style: libraryText(
                              context,
                              14,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
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
                          onPressed:
                              m.frozen ||
                                  m.loading ||
                                  m.reading ||
                                  scope.fileVersion == null
                              ? null
                              : () => _content(
                                  d.targets.firstWhere(
                                    (t) => t.record == scope.record,
                                  ),
                                  scopeId: scope.id,
                                  fileVersion: scope.fileVersion,
                                ),
                          child: Text(
                            scope.fileVersion == null
                                ? '批准附件版本不可用'
                                : '查看批准的附件v${scope.fileVersion}',
                          ),
                        ),
                    ],
                  ),
                ),
              if (d.scopeNotice != null ||
                  d.scopes.any(
                    (s) => s.kind == WorkspaceApprovalScopeKind.field,
                  ))
                Text(
                  d.scopeNotice ?? '可读取以上字段的最新内容；以后新增的字段需要另行申请。',
                  style: libraryText(context, 12, color: c.muted, height: 1.8),
                ),
            ]),
            if (m.linkedDecision &&
                (m.decision.detail!.credentialExpiresAt != null ||
                    m.decision.detail!.credentialSessionBound))
              ApprovalExecutions(controller: m.decision),
            if (d.events.isNotEmpty)
              _section(context, '访问与使用事件', [
                for (final (index, e) in d.events.indexed)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (index < d.events.length - 1)
                        Positioned(
                          left: 5.5,
                          top: 6,
                          bottom: -6,
                          child: Container(width: 1, color: c.line),
                        ),
                      Positioned(
                        left: 2.5,
                        top: 6,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.only(left: 24, bottom: 26),

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
                            if (e.fileScopeId != null && e.fileRecord != null)
                              DesktopButton(
                                key: ValueKey('grant-delivery-${e.id}'),
                                kind: DesktopButtonKind.quiet,
                                onPressed: m.frozen || m.loading || m.reading
                                    ? null
                                    : () => _content(
                                        d.targets.firstWhere(
                                          (v) => v.record == e.fileRecord,
                                        ),
                                        scopeId: e.fileScopeId,
                                        fileVersion: e.fileVersion,
                                        contentLabel:
                                            '实际交付的附件v${e.fileVersion}',
                                      ),
                                child: Text('查看交付的附件v${e.fileVersion}'),
                              ),
                            if (e.proposalId != null)
                              DesktopButton(
                                key: ValueKey(
                                  'grant-organization-${e.proposalId}',
                                ),
                                kind: DesktopButtonKind.quiet,
                                onPressed: m.frozen || widget.onProposal == null
                                    ? null
                                    : () => widget.onProposal!(e.proposalId!),
                                child: const Text('查看这次整理结果'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ])
            else if (h.operationCount == 0)
              _section(context, '访问与使用事件', [
                Text(
                  'AI 尚未使用这次授权。',
                  style: libraryText(context, 13, color: c.muted, height: 1.9),
                ),
              ]),
            _section(context, '关联资料', [
              for (final t in d.targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Tooltip(
                        message: t.exists ? '在信息库中打开' : '资料已删除或不可用',
                        child: DesktopButton(
                          key: ValueKey('grant-current-${t.record.key}'),
                          kind: DesktopButtonKind.link,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          onPressed: m.frozen || !t.exists
                              ? null
                              : () => widget.onRecord(t.record),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: c.selected,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Icon(
                                  t.record.kind ==
                                          WorkspaceRecordKind.credential
                                      ? Icons.key_outlined
                                      : Icons.description_outlined,
                                  size: 18,
                                  color: t.exists ? c.accent : c.muted,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.name,
                                      style: libraryText(
                                        context,
                                        14,
                                        weight: FontWeight.w600,
                                        color: t.exists ? c.ink : c.muted,
                                      ),
                                    ),
                                    if (!t.exists)
                                      Text(
                                        '资料已删除或不可用',
                                        style: libraryText(
                                          context,
                                          12,
                                          color: c.muted,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Icon(Icons.open_in_new, size: 16, color: c.muted),
                            ],
                          ),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (t.record.kind == WorkspaceRecordKind.information)
                            DesktopButton(
                              key: ValueKey('grant-snapshot-${t.record.key}'),
                              kind: DesktopButtonKind.quiet,
                              leading: Icon(
                                _expandedSnapshots.contains(
                                      '${h.id}/${t.record.key}',
                                    )
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                              ),
                              onPressed: m.frozen || !t.snapshotAvailable
                                  ? null
                                  : () => setState(() {
                                      final key = '${h.id}/${t.record.key}';
                                      if (!_expandedSnapshots.add(key)) {
                                        _expandedSnapshots.remove(key);
                                      }
                                    }),
                              child: Text(
                                _expandedSnapshots.contains(
                                      '${h.id}/${t.record.key}',
                                    )
                                    ? '收起审批时的内容'
                                    : '展开审批时的内容',
                              ),
                            ),
                        ],
                      ),
                      if (_expandedSnapshots.contains(
                        '${h.id}/${t.record.key}',
                      ))
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: GrantHistoryContentDialog(
                            key: ValueKey('inline-${h.id}/${t.record.key}'),
                            source: m.source,
                            changes: m.changes,
                            historyId: h.id,
                            record: t.record,
                            label: '审批时的内容',
                            inline: true,
                          ),
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
                child: const Text('撤销这次授权'),
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
      final left = large ? 420.0 : 350.0;
      final list = ColoredBox(
            color: c.rail,
            child: _listPane(context, large || bounds.maxWidth < 900),
          ),
          detail = Container(
            decoration: BoxDecoration(
              color: c.paper,
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
                SizedBox(width: left, child: list),
                Expanded(child: detail),
              ],
            );
    },
  );
}
