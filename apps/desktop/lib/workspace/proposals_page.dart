import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'proposal_editor.dart';
import 'proposal_reading.dart';
import 'proposal_read_dialog.dart';
import 'proposals_controller.dart';
import 'proposal_batch_dialog.dart';
import 'organization_reading.dart';
import 'workspace_source.dart';

String proposalStateLabel(WorkspaceProposalSummary s) =>
    s.organizationOutcome != null
    ? s.organizationOutcome!.label
    : s.status != WorkspaceProposalStatus.completed
    ? s.status.label
    : s.kind == WorkspaceProposalKind.addition
    ? '已入库'
    : s.kind == WorkspaceProposalKind.modification
    ? '已采用'
    : s.kind == WorkspaceProposalKind.deletion
    ? s.wholeDeletion
          ? '已移入回收站'
          : '字段已回收'
    : '已完成';

class ProposalsPage extends StatefulWidget {
  const ProposalsPage({
    super.key,
    required this.controller,
    required this.onRecord,
    this.onModalChanged,
    this.onRetry,
    this.onHistory,
    this.onWorkspaceBack,
    this.workspaceBackLabel = '返回上一页',
  });
  final ProposalsController controller;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final ValueChanged<bool>? onModalChanged;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onHistory;
  final VoidCallback? onWorkspaceBack;
  final String workspaceBackLabel;
  @override
  State<ProposalsPage> createState() => _ProposalsPageState();
}

class _ProposalsPageState extends State<ProposalsPage> {
  ProposalsController get m => widget.controller;
  final _search = TextEditingController();
  final _outcome = GlobalKey();
  WorkspaceFailure? _lastWriteFailure;
  late final ScrollController _list, _detail;
  String? _selection, _state;
  String _query = '';
  bool _restoring = false;
  double _restoreAt = 0;
  double? _restoreListAt;
  @override
  void initState() {
    super.initState();
    _selection = m.selection;
    _state = _stateKey;
    _query = _queryKey;
    _search.text = m.keyword;
    _list = ScrollController(initialScrollOffset: m.listScroll)
      ..addListener(() => m.listScroll = _list.offset);
    _detail = ScrollController(initialScrollOffset: m.detailScroll)
      ..addListener(() {
        if (!_restoring) m.detailScroll = _detail.offset;
      });
    m.addListener(_changed);
  }

  String get _queryKey => '${m.viewRevision}/${m.offset}/${m.limit}';
  String? get _stateKey => m.detail == null
      ? null
      : '${m.detail!.summary.id}/${m.detail!.summary.version}/${m.detail!.summary.status.name}';
  void _changed() {
    if (!mounted) return;
    if (_query != _queryKey) {
      _query = _queryKey;
      _restoreListAt = m.listScroll;
    }
    if (_restoreListAt != null && !m.loading && !m.reading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_list.hasClients || _restoreListAt == null) return;
        final offset = _restoreListAt!;
        _restoreListAt = null;
        _list.jumpTo(offset.clamp(0, _list.position.maxScrollExtent));
      });
    }
    if (_selection != m.selection || _stateKey != null && _stateKey != _state) {
      _selection = m.selection;
      if (_stateKey != null) _state = _stateKey;
      _restoring = true;
      _restoreAt = m.detailScroll;
    }
    if (_restoring) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detail.hasClients) {
          _detail.jumpTo(_restoreAt.clamp(0, _detail.position.maxScrollExtent));
          _restoring = false;
        }
      });
    }
    if (_search.text != m.keyword && !_search.value.composing.isValid) {
      _search.text = m.keyword;
    }
    if (m.writeFailure != null &&
        !identical(m.writeFailure, _lastWriteFailure)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _outcome.currentContext;
        if (mounted && target != null) {
          Scrollable.ensureVisible(
            target,
            alignment: .9,
            duration: DesktopMotion.duration(context, DesktopMotion.detail),
          );
        }
      });
    }
    _lastWriteFailure = m.writeFailure;
    setState(() {});
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    _list.dispose();
    _detail.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit(WorkspaceProposalItem item) async {
    final d = m.detail, review = m.draft?.items[item.id], catalog = m.catalog;
    if (!m.canEdit || d == null || review == null || catalog == null) return;
    widget.onModalChanged?.call(true);
    try {
      await showDesktopDialog<void>(
        context,
        builder: (_) => ProposalItemEditor(
          item: item.withoutOwnerBefore(),
          review: review,
          catalog: catalog,
          relations: m.source.relations(
            d.summary.id,
            item.id,
            d.summary.version,
          ),
          errors: {
            for (final e
                in m.writeFailure?.fieldErrors.entries ??
                    <MapEntry<String, String>>[])
              if (e.key.startsWith('item:${item.id}:'))
                e.key.substring('item:${item.id}:'.length): e.value,
          },
          onSave: (value) => m.editItem(d.summary.id, d.summary.version, value),
        ),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _read({
    WorkspaceProposalTarget? target,
    WorkspaceProposalItem? item,
  }) async {
    final d = m.detail;
    if (m.frozen || d == null) return;
    final ref = target?.record ?? item?.before?.record.ref,
        review = item == null ? null : m.draft?.items[item.id];
    if (ref == null || item != null && review == null) return;
    widget.onModalChanged?.call(true);
    try {
      await showDesktopDialog<void>(
        context,
        builder: (_) => ProposalReadDialog(
          source: m.source,
          changes: m.changes,
          proposalId: d.summary.id,
          proposalVersion: d.summary.version,
          record: ref,
          label: item == null
              ? '${target!.name} · ${d.summary.kind == WorkspaceProposalKind.deletion ? '删除前' : '当时保存'}v${target.version}'
              : '核对当前资料和原提案',
          item: item?.withoutOwnerBefore(),
          review: review,
          wholeDeletion: d.summary.wholeDeletion,
          catalog: m.catalog,
        ),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _showBatch() async {
    if (m.soloFrozen) return;
    if (m.hasBatchLocation && !m.batch.frozen) await m.returnBatchLocation();
    if (!mounted) return;
    m.rememberBatchLocation();
    String? selected;
    widget.onModalChanged?.call(true);
    try {
      selected = await showDesktopDialog<String>(
        context,
        barrierDismissible: false,
        builder: (_) => ProposalBatchDialog(batch: m.batch),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
    if (selected != null) {
      await m.openBatchResult(selected);
    } else {
      m.forgetBatchLocation();
    }
  }

  Widget _header(BuildContext context) {
    final c = UiPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 25, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.onWorkspaceBack != null)
            DesktopButton(
              key: const ValueKey('workspace-back'),
              kind: DesktopButtonKind.quiet,
              onPressed: m.frozen ? null : widget.onWorkspaceBack,
              child: Text(widget.workspaceBackLabel),
            ),
          Text(
            '录入提案',
            style: libraryText(context, 23, weight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          Text(
            '核对新增与变更，查看整理结果',
            style: libraryText(context, 13, color: c.muted, height: 1.8),
          ),
          const SizedBox(height: 18),
          DesktopTextField(
            key: const ValueKey('proposal-search'),
            controller: _search,
            enabled: !m.frozen,
            onChanged: m.search,
            decoration: const InputDecoration(labelText: '搜索提案与用途'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final f in WorkspaceProposalFilter.values)
                DesktopButton(
                  key: ValueKey('proposal-filter-${f.name}'),
                  selected: m.filter == f,
                  kind: DesktopButtonKind.quiet,
                  onPressed: m.frozen ? null : () => m.setFilter(f),
                  child: Text(switch (f) {
                    WorkspaceProposalFilter.all => '全部',
                    WorkspaceProposalFilter.pending => '待确认',
                    WorkspaceProposalFilter.handled => '已处理',
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          DesktopSelect<String>(
            key: const ValueKey('proposal-kind'),
            value: m.kind?.name ?? 'all',
            items: [
              const DropdownMenuItem(value: 'all', child: Text('所有类型')),
              for (final k in WorkspaceProposalKind.values)
                DropdownMenuItem(value: k.name, child: Text(k.label)),
            ],
            onChanged: m.frozen
                ? null
                : (v) => m.setKind(
                    v == 'all' ? null : WorkspaceProposalKind.values.byName(v!),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, WorkspaceProposalSummary r) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
    child: DesktopButton(
      key: ValueKey('proposal-row-${r.id}'),
      selected: m.selection == r.id,
      kind: DesktopButtonKind.quiet,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 17),
      onPressed: m.frozen ? null : () => m.select(r.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 5,
            children: [
              Text(
                r.kind.label,
                style: libraryText(
                  context,
                  12,
                  color: UiPalette.of(context).muted,
                ),
              ),
              Text(
                proposalStateLabel(r),
                style: libraryText(
                  context,
                  12,
                  color: r.status == WorkspaceProposalStatus.pending
                      ? UiPalette.of(context).warning
                      : UiPalette.of(context).muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            r.title,
            style: libraryText(
              context,
              15,
              weight: FontWeight.w600,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${r.agentClaim} · ${r.itemCount}项',
            style: libraryText(context, 12, color: UiPalette.of(context).muted),
          ),
          if (m.batch.entry(r.id) case final queued?)
            Text(
              '本批次：${queued.action == WorkspaceProposalAction.confirm ? '确认' : '拒绝'} · ${queued.status.label}',
              style: libraryText(
                context,
                12,
                color: UiPalette.of(context).accent,
              ),
            ),
          Text(
            libraryLocalDateTime(r.at),
            style: libraryText(context, 12, color: UiPalette.of(context).muted),
          ),
        ],
      ),
    ),
  );
  Widget _pager(BuildContext context) {
    final r = m.results!;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${r.total} 份提案 · ${r.pending} 份待确认',
            style: libraryText(context, 12, color: UiPalette.of(context).muted),
          ),
          const SizedBox(height: 8),
          DesktopButton(
            key: const ValueKey('proposal-batch-open'),
            onPressed: m.soloFrozen || m.batch.entries.isEmpty
                ? null
                : _showBatch,
            child: Text(
              '${m.hasBatchLocation ? '返回本批次' : '批量清单'} · ${m.batch.entries.length}份',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DesktopButton(
                key: const ValueKey('proposal-prev'),
                onPressed: m.frozen || r.offset == 0
                    ? null
                    : () => m.page((r.offset - m.limit).clamp(0, r.total)),
                child: const Text('上一页'),
              ),
              DesktopButton(
                key: const ValueKey('proposal-next'),
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

  Widget _sidebar(BuildContext context, bool large) {
    final r = m.results,
        head = <Widget>[
          _header(context),
          if (m.loading) const LinearProgressIndicator(),
        ];
    final empty = Padding(
      padding: const EdgeInsets.all(22),
      child: Text(
        m.loading
            ? '正在读取提案…'
            : m.readFailure != null
            ? '提案暂时无法读取，请重试。'
            : '没有匹配的提案。',
        style: libraryText(context, 14, color: UiPalette.of(context).muted),
      ),
    );
    if (large) {
      return ListView(
        key: const ValueKey('proposal-list'),
        controller: _list,
        children: [
          ...head,
          if (r == null || r.items.isEmpty)
            empty
          else
            for (final item in r.items) _row(context, item),
          if (r != null) _pager(context),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...head,
        Expanded(
          child: r == null || r.items.isEmpty
              ? Center(child: empty)
              : ListView.builder(
                  key: const ValueKey('proposal-list'),
                  controller: _list,
                  itemCount: r.items.length,
                  itemBuilder: (context, i) => _row(context, r.items[i]),
                ),
        ),
        if (r != null) _pager(context),
      ],
    );
  }

  Widget _feedback(BuildContext context, {bool writes = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!writes && m.readFailure != null) ...[
        Text(
          m.readFailure!.message,
          style: libraryText(context, 14, color: UiPalette.of(context).danger),
        ),
        const SizedBox(height: 8),
        DesktopButton(
          key: const ValueKey('proposal-retry'),
          onPressed: m.frozen ? null : widget.onRetry ?? m.load,
          child: const Text('重新读取提案'),
        ),
      ],
      if (!writes && m.notice != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            m.notice!,
            style: libraryText(
              context,
              13,
              color: UiPalette.of(context).muted,
              height: 1.8,
            ),
          ),
        ),
      if (writes && m.writeFailure != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            m.writeFailure!.message,
            style: libraryText(
              context,
              14,
              color: UiPalette.of(context).danger,
              height: 1.8,
            ),
          ),
        ),
      if (writes)
        for (final error in m.writeFailure?.fieldErrors.values ?? <String>[])
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).danger,
              ),
            ),
          ),
      if (writes && m.uncertain)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DesktopButton(
            key: const ValueKey('proposal-reconcile'),
            onPressed: m.busy ? null : m.reconcile,
            child: const Text('核对本次提案结果'),
          ),
        ),
      if (!writes &&
          !m.frozen &&
          (m.needsReview || m.writeFailure?.code == 'conflict'))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DesktopButton(
            key: const ValueKey('proposal-review-current'),
            onPressed: m.loading || m.reading ? null : m.reviewCurrent,
            child: const Text('重新核对提案与当前状态'),
          ),
        ),
    ],
  );
  Widget _item(BuildContext context, WorkspaceProposalItem item) {
    final review =
            m.draft?.items[item.id] ??
            WorkspaceProposalItemReview.fromItem(item),
        d = m.detail!,
        c = UiPalette.of(context),
        multiple = d.items.length > 1,
        selected = m.draft?.selected.contains(item.id) ?? false;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (multiple)
            Padding(
              padding: const EdgeInsets.only(bottom: 15),
              child: Semantics(
                checked: selected,
                child: DesktopButton(
                  key: ValueKey('proposal-item-${item.id}'),
                  kind: DesktopButtonKind.quiet,
                  alignment: Alignment.centerLeft,
                  onPressed: m.canEdit
                      ? () => m.chooseItem(item.id, !selected)
                      : null,
                  leading: Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 19,
                    color: selected ? c.accent : c.muted,
                  ),
                  child: Text('${selected ? '选中' : '未选中'} · ${review.name}'),
                ),
              ),
            ),
          if (item.before == null)
            ProposalItemReading(
              item: item,
              review: review,
              catalog: m.catalog!,
              relations: m.source.relations(
                d.summary.id,
                item.id,
                d.summary.version,
              ),
              onRecord: widget.onRecord,
              enabled: !m.frozen,
            )
          else if (d.summary.wholeDeletion) ...[
            Text(
              '删除整条资料',
              style: libraryText(context, 22, weight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              '“${item.before!.record.name}”将移入回收站并保留30天。相关旧授权将失效，恢复资料不会恢复旧授权。',
              style: libraryText(context, 14, color: c.muted, height: 1.9),
            ),
            if (item.beforeState == WorkspaceProposalBeforeState.available)
              ProposalItemReading(
                item: WorkspaceProposalItem(
                  id: item.id,
                  proposed: item.before!,
                ),
                review: WorkspaceProposalItemReview.fromItem(
                  WorkspaceProposalItem(id: item.id, proposed: item.before!),
                ),
                catalog: m.catalog!,
                relations: m.source.relations(
                  d.summary.id,
                  item.id,
                  d.summary.version,
                ),
                onRecord: widget.onRecord,
                enabled: !m.frozen,
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text(
                  item.beforeState == WorkspaceProposalBeforeState.unread
                      ? '原版本暂未读取，请先核对当前状态。'
                      : '原版本内容已不可用，不能确认旧范围。',
                  style: libraryText(context, 14, color: c.warning),
                ),
              ),
            const SizedBox(height: 12),
            DesktopButton(
              key: ValueKey('proposal-compare-${item.id}'),
              kind: DesktopButtonKind.quiet,
              onPressed: m.frozen ? null : () => _read(item: item),
              child: const Text('核对当前资料和原提案'),
            ),
          ] else ...[
            Text(
              item.before!.record.name,
              style: libraryText(context, 22, weight: FontWeight.w700),
            ),
            for (final metadata in [
              (
                label: '资料名称',
                before: item.before!.record.name,
                after: review.name,
              ),
              (
                label: '用途说明',
                before: item.before!.record.description,
                after: review.description,
              ),
            ])
              if (metadata.before != metadata.after)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: ProposalDiff(
                    label: metadata.label,
                    before: proposalValue(metadata.before),
                    after: proposalValue(metadata.after),
                  ),
                ),
            for (final section in proposalChangeSections(item)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 22),
                child: Text(
                  section.title,
                  style: libraryText(context, 18, weight: FontWeight.w600),
                ),
              ),
              for (final change in section.changes)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ProposalDiff(
                        label:
                            '字段：${change.label} · ${switch (change.intent) {
                              WorkspaceProposalFieldIntent.correct => '修正原字段内容',
                              WorkspaceProposalFieldIntent.add => '新增字段',
                              WorkspaceProposalFieldIntent.replace => '替换字段含义',
                              WorkspaceProposalFieldIntent.remove => '删除字段',
                            }}',
                        before:
                            change.intent == WorkspaceProposalFieldIntent.add
                            ? '原资料没有此字段。'
                            : item.beforeState ==
                                  WorkspaceProposalBeforeState.unread
                            ? '原版本暂未读取，请先核对当前状态。'
                            : item.beforeState ==
                                      WorkspaceProposalBeforeState
                                          .unavailable ||
                                  !change.beforeAvailable
                            ? '原版本内容已不可用。'
                            : proposalValue(change.before),
                        currentLabel:
                            d.summary.status ==
                                WorkspaceProposalStatus.conflicted
                            ? '原资料v${item.before!.version}'
                            : '当前内容',
                        after:
                            change.intent == WorkspaceProposalFieldIntent.remove
                            ? '移除该字段；旧内容进入回收站。'
                            : proposalValue(review.values[change.reviewKey]),
                      ),
                      if (change.definition != null &&
                          (change.intent == WorkspaceProposalFieldIntent.add ||
                              change.intent ==
                                  WorkspaceProposalFieldIntent.replace))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            '新字段定义：${change.definition!['label']} · ${const {'text': '文本', 'multiline': '多行文本', 'number': '数字', 'date': '日期'}[change.definition!['type']] ?? '保留结构'}\n${change.definition!['description'] ?? ''}',
                            style: libraryText(
                              context,
                              13,
                              color: c.muted,
                              height: 1.8,
                            ),
                          ),
                        ),
                      Text(
                        switch (change.intent) {
                          WorkspaceProposalFieldIntent.correct => '修正保留原字段身份。',
                          WorkspaceProposalFieldIntent.add =>
                            '新增字段使用新身份；旧授权不包含它。',
                          WorkspaceProposalFieldIntent.replace =>
                            '替换含义使用新身份；旧内容进入回收，旧授权不包含新字段。',
                          WorkspaceProposalFieldIntent.remove =>
                            '删除只影响此字段；恢复时重新分配身份，不恢复旧授权。',
                        },
                        style: libraryText(
                          context,
                          13,
                          color: c.muted,
                          height: 1.8,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Text(
              '只有列出的名称、用途说明及字段变化会写入；目录、标签及凭据关联保持原样。',
              style: libraryText(context, 13, color: c.muted, height: 1.9),
            ),
            const SizedBox(height: 12),
            DesktopButton(
              key: ValueKey('proposal-compare-${item.id}'),
              kind: DesktopButtonKind.quiet,
              onPressed: m.frozen ? null : () => _read(item: item),
              child: const Text('核对当前资料和原提案'),
            ),
          ],
          if (d.summary.kind != WorkspaceProposalKind.deletion) ...[
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: DesktopButton(
                key: ValueKey('proposal-edit-${item.id}'),
                onPressed: m.canEdit ? () => _edit(item) : null,
                child: const Text('编辑提案'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final d = m.detail, c = UiPalette.of(context);
    if (d == null) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _feedback(context),
            Padding(
              padding: const EdgeInsets.all(30),
              child: Text(
                m.loading || m.reading ? '正在读取提案…' : '选择一份提案进行核对',
                style: libraryText(context, 14, color: c.muted),
              ),
            ),
          ],
        ),
      );
    }
    final s = d.summary;
    return SingleChildScrollView(
      key: const ValueKey('proposal-detail-scroll'),
      controller: _detail,
      padding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width <= 1300 ? 19 : 24,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1050),
          child: DesktopEntrance(
            key: ValueKey(s.id),
            child: Container(
              key: const ValueKey('proposal-paper'),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: c.paper,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _feedback(context),
                  Container(
                    padding: const EdgeInsets.only(bottom: 27),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            ProposalPill(
                              proposalStateLabel(s),
                              color: s.status == WorkspaceProposalStatus.pending
                                  ? c.warning
                                  : s.status ==
                                        WorkspaceProposalStatus.completed
                                  ? c.success
                                  : c.muted,
                              background:
                                  s.status == WorkspaceProposalStatus.pending
                                  ? c.credentialSurface
                                  : s.status ==
                                        WorkspaceProposalStatus.completed
                                  ? c.successSurface
                                  : c.rail,
                            ),
                            Text(
                              libraryLocalDateTime(s.at),
                              style: libraryText(context, 12, color: c.muted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          s.title,
                          style: libraryHeading(
                            context,
                            MediaQuery.sizeOf(context).width <= 1300 ? 24 : 27,
                          ),
                        ),
                        const SizedBox(height: 13),
                        Text(
                          s.purpose,
                          style: libraryText(
                            context,
                            14,
                            color: c.muted,
                            height: 1.9,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${s.agentClaim} · ${s.chatClaim}',
                          style: libraryText(context, 12, color: c.muted),
                        ),
                        Text(
                          '名称和用途为Agent自述。',
                          style: libraryText(context, 12, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  if (m.needsNewReview)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        '提案内容或结构已变化，下方按原结构保留旧审阅，不能自动套用。请按当前资料重新生成提案。',
                        style: libraryText(
                          context,
                          14,
                          color: c.warning,
                          height: 1.9,
                        ),
                      ),
                    ),
                  if (d.notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        d.notice!,
                        style: libraryText(
                          context,
                          14,
                          color: c.warning,
                          height: 1.9,
                        ),
                      ),
                    ),
                  if (d.organization case final org?)
                    OrganizationReading(
                      report: org,
                      onRecord: m.frozen ? null : widget.onRecord,
                      onHistory: m.frozen ? null : widget.onHistory,
                      onRefresh: m.frozen ? null : m.load,
                    ),
                  if (d.organization == null)
                    for (final item in m.reviewItems) _item(context, item),
                  if (!s.pending && d.targets.isEmpty && d.organization == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 28),
                      child: Text(
                        s.status == WorkspaceProposalStatus.rejected
                            ? '提案已拒绝，没有改动信息库。'
                            : '原提案内容已不可用。',
                        style: libraryText(context, 14, color: c.muted),
                      ),
                    ),
                  for (final target in d.targets)
                    proposalSection(
                      context,
                      target.name,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            s.kind == WorkspaceProposalKind.deletion
                                ? '删除前的资料v${target.version}；回收不恢复旧授权。'
                                : '当时保存为资料v${target.version}',
                            style: libraryText(context, 13, color: c.muted),
                          ),
                          if (!target.exists)
                            Text(
                              '当前对象已删除或不可用，历史身份仍保留。',
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
                                key: ValueKey(
                                  'proposal-current-${target.record.key}',
                                ),
                                onPressed: m.frozen || !target.exists
                                    ? null
                                    : () => widget.onRecord(target.record),
                                child: const Text('查看当前资料'),
                              ),
                              DesktopButton(
                                key: ValueKey(
                                  'proposal-snapshot-${target.record.key}',
                                ),
                                kind: DesktopButtonKind.quiet,
                                onPressed: m.frozen || !target.snapshotAvailable
                                    ? null
                                    : () => _read(target: target),
                                child: Text(
                                  '查看${s.kind == WorkspaceProposalKind.deletion ? '删除前' : '当时保存'}v${target.version}',
                                ),
                              ),
                            ],
                          ),
                          if (!target.snapshotAvailable)
                            Text(
                              s.kind == WorkspaceProposalKind.deletion
                                  ? '删除前的快照已不可用。'
                                  : '当时保存的快照已不可用。',
                              style: libraryText(context, 13, color: c.muted),
                            ),
                        ],
                      ),
                    ),
                  if (s.pending)
                    Container(
                      margin: const EdgeInsets.only(top: 30),
                      padding: const EdgeInsets.only(top: 22),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.line)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (d.items.length > 1 && d.organization == null)
                            Text(
                              '本次确认 ${m.draft?.selected.length ?? 0} / ${d.items.length} 份资料；未选中的内容不会入库。',
                              style: libraryText(
                                context,
                                13,
                                color: c.muted,
                                height: 1.8,
                              ),
                            ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              DesktopButton(
                                key: const ValueKey(
                                  'proposal-batch-add-confirm',
                                ),
                                onPressed: m.canConfirm
                                    ? () => m.queueForBatch(
                                        WorkspaceProposalAction.confirm,
                                      )
                                    : null,
                                child: Text(
                                  m.batch.entry(s.id) == null
                                      ? '加入批量确认'
                                      : '更新本批次的确认审阅',
                                ),
                              ),
                              DesktopButton(
                                key: const ValueKey(
                                  'proposal-batch-add-reject',
                                ),
                                kind: DesktopButtonKind.quiet,
                                onPressed: m.canReject
                                    ? () => m.queueForBatch(
                                        WorkspaceProposalAction.reject,
                                      )
                                    : null,
                                child: const Text('加入批量拒绝'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              DesktopButton(
                                key: const ValueKey('proposal-reject'),
                                kind: DesktopButtonKind.quiet,
                                onPressed: m.canReject
                                    ? () => m.decide(
                                        WorkspaceProposalAction.reject,
                                      )
                                    : null,
                                child: const Text('拒绝提案'),
                              ),
                              DesktopButton(
                                key: const ValueKey('proposal-confirm'),
                                kind: DesktopButtonKind.primary,
                                onPressed: m.canConfirm
                                    ? () => m.decide(
                                        WorkspaceProposalAction.confirm,
                                      )
                                    : null,
                                child: Text(
                                  s.kind == WorkspaceProposalKind.addition
                                      ? '确认入库'
                                      : d.organization?.legacyReview == true
                                      ? '确认旧版整批分类'
                                      : s.kind == WorkspaceProposalKind.deletion
                                      ? '确认移入回收站'
                                      : '确认修改',
                                ),
                              ),
                            ],
                          ),
                          if (m.busy)
                            const Padding(
                              padding: EdgeInsets.only(top: 14),
                              child: LinearProgressIndicator(),
                            ),
                          if (m.writeFailure != null || m.uncertain)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Container(
                                key: _outcome,
                                child: _feedback(context, writes: true),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, b) {
      final c = UiPalette.of(context),
          large = MediaQuery.textScalerOf(context).scale(1) >= 1.6,
          side = large
              ? 340.0
              : MediaQuery.sizeOf(context).width <= 1300
              ? 275.0
              : 300.0;
      final left = Container(
        decoration: BoxDecoration(
          color: c.rail,
          border: Border(right: BorderSide(color: c.line)),
        ),
        child: _sidebar(context, large || b.maxWidth < 900),
      );
      final right = ColoredBox(color: c.rail, child: _content(context));
      return b.maxWidth < 900
          ? Column(
              children: [
                SizedBox(height: 330, child: left),
                Expanded(child: right),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: side, child: left),
                Expanded(child: right),
              ],
            );
    },
  );
}
