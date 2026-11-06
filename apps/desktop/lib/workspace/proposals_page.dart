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
import 'proposal_passwords.dart';
import 'proposal_content_preview.dart';
import 'proposal_directory.dart';

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
    this.passwords,
    this.onFile,
    required this.onRecord,
    this.onModalChanged,
    this.onRetry,
    this.onHistory,
    this.onWorkspaceBack,
    this.workspaceBackLabel = '返回上一页',
  });
  final ProposalsController controller;
  final ProposalPasswords? passwords;
  final WorkspaceProposalFileOpener? onFile;
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
  final _savedSelection = <String, WorkspaceRecordRef>{};
  bool _restoring = false;
  double _restoreAt = 0;
  double? _restoreListAt;
  @override
  void initState() {
    super.initState();
    m.bindPasswords(widget.passwords);
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
      : '${m.detail!.summary.id}/${m.detail!.summary.version}/${m.detail!.summary.status.name}/${m.activeItemId}';
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

  @override
  void didUpdateWidget(covariant ProposalsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    m.bindPasswords(widget.passwords);
  }

  ProposalPendingFileReader? _pendingReader(
    WorkspaceProposalDetail d,
    WorkspaceProposalItem item, {
    WorkspaceProposalItemReview? review,
  }) {
    final source = m.source;
    if (source is! WorkspaceProposalOriginalSource) return null;
    return (key, version, page) =>
        (source as WorkspaceProposalOriginalSource).pendingOriginal(
          d.summary.id,
          d.summary.version,
          item.id,
          key,
          version,
          page: page,
          review: review,
          originalProposalVersion: item.originalProposalVersion,
        );
  }

  ProposalStoredFileReader? _storedReader(
    WorkspaceProposalDetail d, {
    WorkspaceProposalItemReview? review,
  }) {
    final source = m.source;
    if (source is! WorkspaceProposalOriginalSource) return null;
    return (detail, key, file, page) =>
        (source as WorkspaceProposalOriginalSource).storedOriginal(
          d.summary.id,
          d.summary.version,
          detail.record.ref,
          key,
          file,
          page: page,
          review: review,
        );
  }

  Future<void> _previewRelated(WorkspaceRecordRef ref) async {
    final detail = m.detail;
    if (detail == null || m.frozen) return;
    final proposedId = ref.id.startsWith('pending:')
        ? 'proposal:${ref.id.substring('pending:'.length)}'
        : ref.id;
    final item = m.reviewItems.where((i) => i.id == proposedId).firstOrNull;
    if (item != null) {
      m.selectItem(item.id);
      return;
    }
    final source = m.source;
    if (source is! WorkspaceProposalPreviewSource) return;
    final previews = source as WorkspaceProposalPreviewSource;
    final review = m.draft?.items[m.activeItemId];
    widget.onModalChanged?.call(true);
    try {
      await showDesktopDialog<void>(
        context,
        builder: (context) => DesktopDialog(
          title: const Text('关联资料预览'),
          content: ProposalContentPreview(
            changes: m.changes,
            readingState: m.readingState('related:${ref.key}'),
            load: () => previews.previewRelated(
              detail.summary.id,
              detail.summary.version,
              ref,
              review: review,
            ),
            catalog: m.catalog!,
            relations: m.activeItemId == null
                ? previews.previewRelations()
                : m.source.relations(
                    detail.summary.id,
                    m.activeItemId!,
                    detail.summary.version,
                  ),
            readStoredFile: _storedReader(detail, review: review),
            pendingReader: (item) =>
                _pendingReader(detail, item, review: review),
          ),
          actions: [
            DesktopButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _restartReview() async {
    final id = m.detail?.summary.id;
    if (id == null || m.frozen || !m.needsNewReview) return;
    widget.onModalChanged?.call(true);
    try {
      final accepted = await showDesktopDialog<bool>(
        context,
        builder: (context) => DesktopDialog(
          title: const Text('重新审阅当前提案'),
          content: const Text('这会放弃本页旧审阅的未保存编辑，重新读取当前提案。已有资料不会改变，也不会自动批准。'),
          actions: [
            DesktopButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留旧审阅'),
            ),
            DesktopButton(
              key: const ValueKey('proposal-restart-review-confirm'),
              kind: DesktopButtonKind.primary,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新审阅'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      await m.restartReview(id);
      if (mounted && _detail.hasClients) _detail.jumpTo(0);
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
            [
              if (r.agentClaim.isNotEmpty) r.agentClaim,
              '${r.itemCount}项',
            ].join(' · '),
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
        directoryCatalog = proposalDirectoryCatalog(
          m.catalog!,
          m.draft?.items.values ?? [review],
        ),
        c = UiPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (item.before == null)
            ProposalItemReading(
              passwordInput: item.credential?.source != 'owner'
                  ? null
                  : widget.passwords?.input(
                          d.summary.id,
                          d.summary.version,
                          item.id,
                          enabled: m.canEdit,
                        ) ??
                        Text(
                          item.credential!.ready
                              ? '密码已填写'
                              : '密码输入暂不可用，请重新打开应用。',
                        ),
              item: item,
              review: review,
              catalog: directoryCatalog,
              onDirectoryChanged: m.canEdit
                  ? (id) => m.editItem(
                      d.summary.id,
                      d.summary.version,
                      WorkspaceProposalItemReview(
                        itemId: review.itemId,
                        name: review.name,
                        description: review.description,
                        values: review.values,
                        directoryId: id.id,
                        suggestedDirectory: id.proposedPath,
                        tagIds: review.tagIds,
                        relations: review.relations,
                      ),
                    )
                  : null,
              relations: m.source.relations(
                d.summary.id,
                item.id,
                d.summary.version,
              ),
              onRecord: _previewRelated,
              enabled: !m.frozen,
              originalsEnabled: !m.needsNewReview,
              readingState: m.readingState(item.id),
              readPendingFile: _pendingReader(d, item, review: review),
              readStoredFile: _storedReader(d, review: review),
              onFile: widget.onFile == null
                  ? null
                  : (key, version) async {
                      widget.onModalChanged?.call(true);
                      try {
                        await widget.onFile!(
                          d.summary.id,
                          d.summary.version,
                          item.id,
                          key,
                          version,
                        );
                      } finally {
                        widget.onModalChanged?.call(false);
                      }
                    },
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
                catalog: directoryCatalog,
                relations: m.source.relations(
                  d.summary.id,
                  item.id,
                  d.summary.version,
                ),
                onRecord: _previewRelated,
                enabled: !m.frozen,
                originalsEnabled: !m.needsNewReview,
                readingState: m.readingState(item.id),
                readStoredFile: _storedReader(d, review: review),
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
            ProposalItemComparison(
              item: item,
              review: review,
              catalog: directoryCatalog,
              onDirectoryChanged: m.canEdit
                  ? (id) => m.editItem(
                      d.summary.id,
                      d.summary.version,
                      WorkspaceProposalItemReview(
                        itemId: review.itemId,
                        name: review.name,
                        description: review.description,
                        values: review.values,
                        directoryId: id.id,
                        suggestedDirectory: id.proposedPath,
                        tagIds: review.tagIds,
                        relations: review.relations,
                      ),
                    )
                  : null,
              relations: m.source.relations(
                d.summary.id,
                item.id,
                d.summary.version,
              ),
              onRecord: _previewRelated,
              enabled: !m.frozen,
              originalsEnabled: !m.needsNewReview,
              readingState: m.readingState(item.id),
              readPendingFile: _pendingReader(d, item, review: review),
              readStoredFile: _storedReader(d, review: review),
              onFile: widget.onFile == null
                  ? null
                  : (key, version) => widget.onFile!(
                      d.summary.id,
                      d.summary.version,
                      item.id,
                      key,
                      version,
                    ),
            ),
          ],
          if (!d.summary.wholeDeletion &&
              item.before != null &&
              d.summary.status == WorkspaceProposalStatus.conflicted)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: DesktopButton(
                key: ValueKey('proposal-compare-${item.id}'),
                kind: DesktopButtonKind.quiet,
                onPressed: m.frozen ? null : () => _read(item: item),
                child: const Text('核对后来发生的修改'),
              ),
            ),
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
                        if (s.purpose.isNotEmpty) ...[
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
                        ],
                        if (s.agentClaim.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            s.agentClaim,
                            style: libraryText(context, 12, color: c.muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (m.needsNewReview)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '提案内容或结构已变化，下方保留旧审阅。请重新审阅当前提案后再决定。',
                            style: libraryText(
                              context,
                              14,
                              color: c.warning,
                              height: 1.9,
                            ),
                          ),
                          const SizedBox(height: 10),
                          DesktopButton(
                            key: const ValueKey('proposal-restart-review'),
                            onPressed: m.frozen || m.loading || m.reading
                                ? null
                                : _restartReview,
                            child: const Text('重新审阅当前提案'),
                          ),
                        ],
                      ),
                    ),
                  for (final notice in [
                    ?d.notice,
                    if (s.pending && d.items.any(m.isPasswordMissing))
                      '请填写密码，整份内容齐全后保存。',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        notice,
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
                  if (d.organization == null && m.reviewItems.isNotEmpty) ...[
                    ProposalDirectorySummary(
                      catalog: m.catalog!,
                      reviews: [
                        for (final i in m.reviewItems)
                          m.draft?.items[i.id] ??
                              WorkspaceProposalItemReview.fromItem(i),
                      ],
                    ),
                    if (m.reviewItems.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (index, item) in m.reviewItems.indexed)
                              ChoiceChip(
                                showCheckmark: false,
                                key: ValueKey('proposal-tab-${item.id}'),
                                selected: m.activeItemId == item.id,
                                onSelected: m.frozen
                                    ? null
                                    : (_) => m.selectItem(item.id),
                                label: Text(
                                  '${index + 1}. ${m.draft?.items[item.id]?.name ?? item.proposed.record.name}${m.isPasswordMissing(item) ? ' · 待填密码' : ''}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    for (final item in m.reviewItems)
                      if (item.id == m.activeItemId)
                        KeyedSubtree(
                          key: ValueKey('proposal-active-${item.id}'),
                          child: _item(context, item),
                        ),
                  ],
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
                  if (d.targets.isNotEmpty &&
                      m.source is WorkspaceProposalPreviewSource) ...[
                    if (d.targets.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final target in d.targets)
                              ChoiceChip(
                                showCheckmark: false,
                                key: ValueKey(
                                  'proposal-saved-tab-${target.record.key}',
                                ),
                                selected:
                                    (_savedSelection[s.id] ??
                                        d.targets.first.record) ==
                                    target.record,
                                onSelected: (_) => setState(
                                  () => _savedSelection[s.id] = target.record,
                                ),
                                label: Text(target.name),
                              ),
                          ],
                        ),
                      ),
                    for (final target in d.targets)
                      if ((_savedSelection[s.id] ?? d.targets.first.record) ==
                          target.record)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: ProposalContentPreview(
                            changes: m.changes,
                            readStoredFile: _storedReader(d),
                            readingState: m.readingState(
                              'saved:${target.record.key}',
                            ),
                            key: ValueKey((
                              'saved-preview',
                              s.id,
                              target.record,
                              target.version,
                            )),
                            load: () =>
                                (m.source as WorkspaceProposalPreviewSource)
                                    .savedPreview(s.id, target.record),
                            catalog: m.catalog!,
                            relations:
                                (m.source as WorkspaceProposalPreviewSource)
                                    .previewRelations(),
                          ),
                        ),
                  ],
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
                              '共 ${d.items.length} 条信息，填齐后一起保存。',
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
                                onPressed: m.canQueueConfirm
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
                                      ? '保存整份提案'
                                      : d.organization?.legacyReview == true
                                      ? '确认旧版整批分类'
                                      : s.kind == WorkspaceProposalKind.deletion
                                      ? '确认移入回收站'
                                      : '保存整份修改',
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
