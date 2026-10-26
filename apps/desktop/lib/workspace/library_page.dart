import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../desktop_motion.dart';
import '../desktop_scroll.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_controller.dart';
import 'library_detail.dart';
import 'library_directory_dialog.dart';
import 'library_edit_dialog.dart';
import 'library_history_dialog.dart';
import 'library_credential_lifecycle.dart';
import 'library_recycle.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'library_adoption_dialog.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    required this.onNavigate,
    this.onModalChanged,
    this.onRetry,
    this.filePicker,
    this.credentialPicker,
  });
  final LibraryController controller;
  final void Function(WorkspacePage, String) onNavigate;
  final ValueChanged<bool>? onModalChanged;
  final VoidCallback? onRetry;
  final WorkspaceFilePicker? filePicker;
  final WorkspaceCredentialPicker? credentialPicker;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _list = ScrollController(), _detailScroll = ScrollController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  int _focusRequest = 0, _viewReset = 0;
  bool _reading = false, _recyclePage = false;
  WorkspaceRecordRef? _lastSelection;
  LibraryController get model => widget.controller;
  @override
  void initState() {
    super.initState();
    _search.text = model.query.keyword;
    _lastSelection = model.selection;
    model.addListener(_changed);
    _focusRequest = model.searchFocusRequest;
    _viewReset = model.viewReset;
    if (_focusRequest > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
    _list.addListener(() {
      model.scrollOffset = _list.offset;
    });
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _list.dispose();
    _detailScroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_search.text != model.query.keyword &&
        !_search.value.composing.isValid) {
      _search.text = model.query.keyword;
    }
    if (_viewReset != model.viewReset) {
      _viewReset = model.viewReset;
      _recyclePage = _reading = false;
    }
    setState(() {});
    if (_lastSelection != model.selection) {
      _lastSelection = model.selection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detailScroll.hasClients) _detailScroll.jumpTo(0);
      });
    }
    if (_focusRequest != model.searchFocusRequest) {
      _focusRequest = model.searchFocusRequest;
      setState(() {
        _recyclePage = _reading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_list.hasClients) return;
      final target = model.scrollOffset.clamp(
        0,
        _list.position.maxScrollExtent,
      );
      if ((_list.offset - target).abs() > .5) _list.jumpTo(target.toDouble());
    });
  }

  Future<void> _edit({bool create = false}) async {
    if (model.loadState == WorkspaceLoad.loading) return;
    widget.onModalChanged?.call(true);
    try {
      final ref = await showLibraryEditor(
        context,
        model,
        detail: create ? null : model.detail,
        filePicker: widget.filePicker,
        credentialPicker: widget.credentialPicker,
      );
      if (!mounted || ref == null) return;
      await model.openRelated(ref, rememberOrigin: create);
      if (mounted) {
        DesktopFeedback.show(
          context,
          model.detail?.record.ref == ref
              ? (create ? '已添加资料' : '已保存资料')
              : '操作已提交，当前资料暂不可用，请查看读取结果。',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _history() async {
    final ref = model.detail?.record.ref;
    if (ref == null) return;
    widget.onModalChanged?.call(true);
    try {
      final restored = ref.kind == WorkspaceRecordKind.credential
          ? await showCredentialMaterials(context, model.source, ref)
          : await showLibraryHistory(context, model.source, ref);
      if (!mounted || restored != true) return;
      await model.openRelated(ref, rememberOrigin: false);
      if (mounted) {
        DesktopFeedback.show(
          context,
          model.detail?.record.ref == ref
              ? '已恢复为新版本'
              : '恢复已提交，当前资料暂不可用，请查看读取结果。',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _adopt() async {
    final ref = model.detail?.record.ref;
    if (ref == null || ref.kind != WorkspaceRecordKind.information) return;
    widget.onModalChanged?.call(true);
    try {
      final adopted = await showLibraryAdoption(context, model.source, ref);
      if (mounted && adopted != null) {
        await model.openRelated(adopted, rememberOrigin: false);
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _recycleCurrent() async {
    final detail = model.detail;
    if (detail == null) return;
    widget.onModalChanged?.call(true);
    try {
      final receipt = await showLibraryRecycle(
        context,
        model.source,
        current: detail,
      );
      if (!mounted || receipt == null) return;
      await model.load(model.query);
      if (mounted) DesktopFeedback.show(context, '已移到回收站');
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  void _toggleReading() {
    _reading = !_reading;
    _changed();
  }

  Future<void> _changeDirectory(
    WorkspaceDirectoryAction action, {
    WorkspaceDirectory? directory,
    String? parent,
  }) async {
    if (model.loadState == WorkspaceLoad.loading) return;
    widget.onModalChanged?.call(true);
    try {
      final saved = await showLibraryDirectoryEditor(
        context,
        model,
        action: action,
        directory: directory,
        initialParent: parent,
      );
      if (saved && mounted) {
        DesktopFeedback.show(
          context,
          action == WorkspaceDirectoryAction.delete ? '已删除空目录' : '目录已保存',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Widget _directory(
    BuildContext context,
    WorkspaceDirectory directory,
    LibraryMetrics metrics,
  ) {
    final selected = (model.query.directoryId ?? 'all') == directory.id;
    final path = libraryDirectoryAncestors(model.catalog!, directory);
    final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
    final count = '${model.catalog?.directoryCounts[directory.id] ?? 0}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Expanded(
            child: DesktopButton(
              key: ValueKey('library-directory-${directory.id}'),
              tooltip: path.map((d) => d.name).join(' › '),
              selected: selected,
              kind: DesktopButtonKind.quiet,
              onPressed: () => directory.id == 'all'
                  ? model.showAll()
                  : model.apply(
                      model.query.copyWith(directoryId: directory.id),
                    ),
              fontSize: metrics.compact ? 13 : 14,
              padding: EdgeInsets.fromLTRB(
                10 + (path.length - 1).clamp(0, 3) * (largeText ? 10.0 : 22.0),
                8,
                10,
                8,
              ),
              minimumSize: const Size(0, 39),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  PrototypeIcon(
                    directory.id == 'all'
                        ? PrototypeIconGlyph.grid
                        : PrototypeIconGlyph.folder,
                    size: 17,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          directory.name,
                          maxLines: largeText ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (largeText)
                          Text(
                            '$count 项',
                            style: libraryText(
                              context,
                              12,
                              color: UiPalette.of(context).muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!largeText) ...[
                    const SizedBox(width: 5),
                    Text(
                      count,
                      style: libraryText(
                        context,
                        12,
                        color: UiPalette.of(context).muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _directoryMenu(WorkspaceDirectory directory) => DesktopSelect<String>(
    key: ValueKey('library-directory-actions-${directory.id}'),
    compact: true,
    quiet: true,
    triggerLabel: Semantics(
      label: '目录操作：${directory.name}',
      child: const PrototypeIcon(PrototypeIconGlyph.more, size: 16),
    ),
    items: const [
      DropdownMenuItem(value: 'child', child: Text('新建子目录')),
      DropdownMenuItem(value: 'edit', child: Text('重命名或移动')),
      DropdownMenuItem(value: 'delete', child: Text('删除空目录')),
    ],
    onChanged: model.loadState == WorkspaceLoad.loading
        ? null
        : (action) {
            switch (action) {
              case 'child':
                _changeDirectory(
                  WorkspaceDirectoryAction.create,
                  parent: directory.id,
                );
              case 'edit':
                _changeDirectory(
                  WorkspaceDirectoryAction.update,
                  directory: directory,
                );
              case 'delete':
                _changeDirectory(
                  WorkspaceDirectoryAction.delete,
                  directory: directory,
                );
            }
          },
  );

  Widget _side(BuildContext context, LibraryMetrics metrics) {
    final c = UiPalette.of(context), catalog = model.catalog;
    final current = catalog?.directories
        .where(
          (d) =>
              d.id == model.query.directoryId &&
              !['all', 'unfiled'].contains(d.id),
        )
        .firstOrNull;
    return Container(
      key: const ValueKey('library-directory-pane'),
      width: metrics.directoryWidth,
      decoration: BoxDecoration(
        color: c.rail,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 20, 10, 18),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(21, 13, 0, 13),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 33),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '资料目录',
                            style: libraryText(
                              context,
                              12,
                              color: c.muted,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (current != null) _directoryMenu(current),
                      ],
                    ),
                  ),
                ),
                if (catalog != null) ...[
                  for (final directory in libraryDirectoryTree(catalog))
                    _directory(context, directory, metrics),
                  DesktopButton(
                    key: const ValueKey('library-directory-create'),
                    kind: DesktopButtonKind.quiet,
                    alignment: Alignment.centerLeft,
                    leading: const PrototypeIcon(
                      PrototypeIconGlyph.plus,
                      size: 17,
                    ),
                    onPressed: model.loadState == WorkspaceLoad.loading
                        ? null
                        : () => _changeDirectory(
                            WorkspaceDirectoryAction.create,
                            parent:
                                [
                                  'all',
                                  'unfiled',
                                ].contains(model.query.directoryId)
                                ? null
                                : model.query.directoryId,
                          ),
                    child: const Text('新建目录'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 15,
                    ),
                    child: Divider(height: 1, color: c.line),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(21, 6, 0, 10),
                          child: Text(
                            '标签',
                            style: libraryText(context, 12, color: c.muted),
                          ),
                        ),
                      ),
                      DesktopButton(
                        kind: DesktopButtonKind.quiet,
                        fontSize: 12,
                        minimumSize: const Size(0, 25),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        onPressed: () =>
                            widget.onNavigate(WorkspacePage.settings, 'labels'),
                        child: const Text('管理'),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final tag in catalog.tags.take(7))
                          LibraryTag(
                            tag.name,
                            selected: model.query.tagId == tag.id,
                            onPressed: () => model.apply(
                              model.query.copyWith(
                                tagId: tag.id,
                                clearTag: model.query.tagId == tag.id,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: DesktopButton(
              key: const ValueKey('library-open-recycle'),
              kind: DesktopButtonKind.quiet,
              alignment: Alignment.centerLeft,
              onPressed: () => setState(() {
                _recyclePage = true;
                _reading = false;
              }),
              child: Text('回收站 · ${catalog?.recycledCount ?? 0}'),
            ),
          ),
        ],
      ),
    );
  }

  String get _directoryName =>
      model.catalog?.directories
          .where((d) => d.id == (model.query.directoryId ?? 'all'))
          .firstOrNull
          ?.name ??
      '全部资料';
  Widget _header(BuildContext context) {
    final c = UiPalette.of(context),
        query = model.query,
        catalog = model.catalog;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _directoryName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: libraryText(
                    context,
                    17,
                    height: 1.5,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              DesktopButton(
                key: const ValueKey('library-create'),
                kind: DesktopButtonKind.quiet,
                onPressed:
                    catalog == null || model.loadState == WorkspaceLoad.loading
                    ? null
                    : () => _edit(create: true),
                minimumSize: const Size(30, 36),
                padding: const EdgeInsets.all(6),
                tooltip: '添加资料',
                child: const PrototypeIcon(PrototypeIconGlyph.plus, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Container(
            height: 39 * MediaQuery.textScalerOf(context).scale(1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.paper,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                const PrototypeIcon(PrototypeIconGlyph.search, size: 16),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    key: const ValueKey('library-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    onChanged: (s) => model.apply(query.copyWith(keyword: s)),
                    style: libraryText(context, 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      hintText: '搜索名称、用途、标签',
                    ),
                  ),
                ),
                Text('⌘ K', style: libraryText(context, 11, color: c.muted)),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: DesktopSelect<String?>(
                  key: const ValueKey('library-type-filter'),
                  value: query.typeId,
                  compact: true,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部类型')),
                    for (final type in catalog?.types ?? <WorkspaceType>[])
                      DropdownMenuItem(value: type.id, child: Text(type.name)),
                  ],
                  onChanged: (v) => model.apply(
                    query.copyWith(typeId: v, clearType: v == null),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DesktopSelect<String?>(
                  key: const ValueKey('library-tag-filter'),
                  value: query.tagId,
                  compact: true,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部标签')),
                    for (final tag in catalog?.tags ?? <WorkspaceTag>[])
                      DropdownMenuItem(value: tag.id, child: Text(tag.name)),
                  ],
                  onChanged: (v) => model.apply(
                    query.copyWith(tagId: v, clearTag: v == null),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    model.loadState == WorkspaceLoad.loading
                        ? '正在更新…'
                        : '${model.results?.total ?? 0} 项',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ),
                DesktopSelect<WorkspaceGrouping>(
                  key: const ValueKey('library-group'),
                  value: query.grouping,
                  compact: true,
                  quiet: true,
                  leading: const PrototypeIcon(
                    PrototypeIconGlyph.grid,
                    size: 15,
                  ),
                  triggerLabel: const Text('分组'),
                  items: [
                    for (final g in WorkspaceGrouping.values)
                      DropdownMenuItem(value: g, child: Text(_groupName(g))),
                  ],
                  onChanged: (v) => model.apply(query.copyWith(grouping: v)),
                ),
                const SizedBox(width: 5),
                DesktopSelect<WorkspaceSort>(
                  key: const ValueKey('library-sort'),
                  value: query.sort,
                  compact: true,
                  quiet: true,
                  leading: const PrototypeIcon(
                    PrototypeIconGlyph.sort,
                    size: 15,
                  ),
                  triggerLabel: const Text('排序'),
                  items: const [
                    DropdownMenuItem(
                      value: WorkspaceSort.updated,
                      child: Text('最近更新'),
                    ),
                    DropdownMenuItem(
                      value: WorkspaceSort.name,
                      child: Text('名称'),
                    ),
                  ],
                  onChanged: (v) => model.apply(query.copyWith(sort: v)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _groupName(WorkspaceGrouping g) => switch (g) {
    WorkspaceGrouping.none => '不分组',
    WorkspaceGrouping.type => '按类型',
    WorkspaceGrouping.directory => '按目录',
  };
  String _groupKey(WorkspaceRecordSummary r) => switch (model.query.grouping) {
    WorkspaceGrouping.none => '',
    WorkspaceGrouping.type => r.type.id,
    WorkspaceGrouping.directory => r.directoryId ?? 'unfiled',
  };
  String _groupLabel(WorkspaceRecordSummary r) =>
      switch (model.query.grouping) {
        WorkspaceGrouping.none => '',
        WorkspaceGrouping.type => r.type.name,
        WorkspaceGrouping.directory =>
          model.catalog?.directories
                  .where((d) => d.id == (r.directoryId ?? 'unfiled'))
                  .firstOrNull
                  ?.name ??
              '未分类',
      };

  Widget _record(BuildContext context, WorkspaceRecordSummary r) {
    final c = UiPalette.of(context), selected = model.selection == r.ref;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: DesktopButton(
        key: ValueKey('library-record-${r.ref.key}'),
        radius: 8,
        selectedBorder: true,
        kind: DesktopButtonKind.quiet,
        selected: selected,
        onPressed: () => model.select(r.ref),
        // CSS border-box includes a 1px border outside its 12/14px padding.
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 15),
        alignment: Alignment.topLeft,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RecordIcon(r.type),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    r.name,
                    style: libraryText(
                      context,
                      14,
                      weight: FontWeight.w700,
                      color: selected ? c.accent : c.ink,
                    ),
                  ),
                  if (r.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        r.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: libraryText(
                          context,
                          13,
                          height: 1.7,
                          color: c.muted,
                        ),
                      ),
                    ),
                  Padding(
                    // Adjacent CSS margins collapse: max(summary bottom5, meta top8).
                    padding: EdgeInsets.only(
                      top: r.description.isEmpty ? 8 : 3,
                    ),
                    child: Text(
                      r.type.name,
                      style: libraryText(context, 12, color: c.muted),
                    ),
                  ),
                  if (r.tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          for (final tag in r.tags.take(2))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: selected ? c.paper : c.rail,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                tag.name,
                                style: libraryText(
                                  context,
                                  12,
                                  height: 1.5,
                                  color: c.muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, LibraryMetrics metrics) {
    final c = UiPalette.of(context), results = model.results;
    Widget contents;
    if (model.loadState == WorkspaceLoad.error) {
      contents = SingleChildScrollView(
        primary: false,
        child: LibraryMessage(
          '暂时无法读取',
          description: model.failure?.message,
          action: DesktopButton(
            onPressed: widget.onRetry ?? () => model.load(model.query),
            child: const Text('重试'),
          ),
        ),
      );
    } else if (results == null) {
      contents = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (results.total == 0) {
      final empty = (model.catalog?.directoryCounts['all'] ?? 0) == 0;
      contents = SingleChildScrollView(
        primary: false,
        child: LibraryMessage(
          empty ? '暂无资料' : '没有匹配的资料',
          description: empty ? '添加一份资料开始整理。' : '换个关键词，或取消类型和标签。',
          action: DesktopButton(
            onPressed: empty ? () => _edit(create: true) : model.clearFilters,
            child: Text(empty ? '添加资料' : '清除筛选'),
          ),
        ),
      );
    } else {
      final rows = <Widget>[];
      for (var i = 0; i < results.items.length; i++) {
        final r = results.items[i], group = _groupKey(r);
        if (group.isNotEmpty &&
            (i == 0 || _groupKey(results.items[i - 1]) != group)) {
          rows.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _groupLabel(r),
                      style: libraryText(context, 12, color: c.muted),
                    ),
                  ),
                  Text(
                    '${results.groupCounts[group] ?? 0}',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ],
              ),
            ),
          );
        }
        rows.add(_record(context, r));
      }
      contents = ListView(
        key: const ValueKey('library-results-scroll'),
        controller: _list,
        padding: const EdgeInsets.fromLTRB(18, 3, 4, 18),
        children: rows,
      );
    }
    return Container(
      key: const ValueKey('library-results-pane'),
      width: metrics.resultsWidth,
      decoration: BoxDecoration(
        color: c.canvas,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          _header(context),
          Expanded(child: contents),
          Container(
            key: const ValueKey('library-results-footer'),
            constraints: const BoxConstraints(minHeight: 45),
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_groupName(model.query.grouping)} · ${model.query.sort == WorkspaceSort.name ? '按名称' : '最近更新优先'}',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ),
                if ((results?.total ?? 0) > model.query.limit) ...[
                  DesktopButton(
                    tooltip: '上一页',
                    kind: DesktopButtonKind.quiet,
                    fontSize: 12,
                    onPressed: model.query.offset == 0
                        ? null
                        : () => model.load(
                            model.query.copyWith(
                              offset: (model.query.offset - model.query.limit)
                                  .clamp(0, results!.total),
                            ),
                          ),
                    child: const Text('‹'),
                  ),
                  DesktopButton(
                    tooltip: '下一页',
                    kind: DesktopButtonKind.quiet,
                    fontSize: 12,
                    onPressed:
                        model.query.offset + model.query.limit >=
                            (results?.total ?? 0)
                        ? null
                        : () => model.load(
                            model.query.copyWith(
                              offset: model.query.offset + model.query.limit,
                            ),
                          ),
                    child: const Text('›'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, LibraryMetrics metrics) {
    final c = UiPalette.of(context), detail = model.detail;
    final name =
        model.catalog?.directories
            .where((d) => d.id == (detail?.record.directoryId ?? 'unfiled'))
            .firstOrNull
            ?.name ??
        '未分类';
    return Container(
      key: const ValueKey('library-detail-pane'),
      margin: metrics.detailMargin,
      decoration: BoxDecoration(
        color: c.paper,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 49),
            padding: EdgeInsets.symmetric(horizontal: metrics.toolbarPadding),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                if (_reading)
                  DesktopButton(
                    onPressed: _toggleReading,
                    kind: DesktopButtonKind.quiet,
                    leading: const PrototypeIcon(
                      PrototypeIconGlyph.back,
                      size: 16,
                    ),
                    child: const Text('退出展开'),
                  ),
                if (model.canGoBack)
                  DesktopButton(
                    key: const ValueKey('library-back'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: model.goBack,
                    tooltip: '返回原查询',
                    padding: const EdgeInsets.all(6),
                    child: const PrototypeIcon(
                      PrototypeIconGlyph.back,
                      size: 16,
                    ),
                  ),
                Expanded(
                  child: Text(
                    detail == null
                        ? _directoryName
                        : '$name / ${detail.record.type.name}',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                ),
                DesktopButton(
                  kind: DesktopButtonKind.quiet,
                  fontSize: 12,
                  onPressed:
                      model.catalog == null ||
                          model.loadState == WorkspaceLoad.loading
                      ? null
                      : () => _edit(create: true),
                  child: const Text('添加资料'),
                ),
              ],
            ),
          ),
          if (model.navigationNotice != null || model.scopeNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                model.navigationNotice ?? model.scopeNotice!,
                style: libraryText(context, 12, color: c.muted),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('library-detail-scroll'),
              controller: _detailScroll,
              padding: metrics.detailPadding,
              child: model.loadState == WorkspaceLoad.error
                  ? LibraryMessage('资料暂不可用')
                  : detail == null
                  ? LibraryMessage(
                      model.detailFailure?.code == 'not_found'
                          ? '资料已不存在'
                          : '选择一份资料',
                      description:
                          model.detailFailure?.message ?? '查看内容、文件与关联关系。',
                    )
                  : DesktopEntrance(
                      key: ValueKey(detail.record.ref),
                      child: LibraryDetail(
                        key: ValueKey(detail.record.ref),
                        detail: detail,
                        source: model.source,
                        metrics: metrics,
                        revision: model.revision,
                        filePicker: widget.filePicker,
                        credentialPicker: widget.credentialPicker,
                        onModalChanged: widget.onModalChanged,
                        onOpen: model.openRelated,
                        onEdit: model.loadState == WorkspaceLoad.loading
                            ? null
                            : () => _edit(),
                        onHistory: model.loadState != WorkspaceLoad.loading
                            ? _history
                            : null,
                        onRecycle: model.loadState != WorkspaceLoad.loading
                            ? _recycleCurrent
                            : null,
                        onAdopt:
                            model.loadState != WorkspaceLoad.loading &&
                                detail.record.ref.kind ==
                                    WorkspaceRecordKind.information
                            ? _adopt
                            : null,
                        onTag: (id) =>
                            model.apply(model.query.copyWith(tagId: id)),
                        onSettings: () => widget.onNavigate(
                          WorkspacePage.settings,
                          'plugin:builtin.server/host:${detail.record.ref.id}',
                        ),
                        onExpand: _toggleReading,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (_reading)
        const SingleActivator(LogicalKeyboardKey.escape): _toggleReading,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
          _searchFocus.requestFocus,
    },
    child: ScrollConfiguration(
      behavior: const DesktopScrollBehavior(scrollbarGutter: 11),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final metrics = LibraryMetrics(bounds.maxWidth);
          if (_recyclePage) {
            return LibraryRecyclePage(
              source: model.source,
              onModalChanged: widget.onModalChanged,
              onBack: () => setState(() => _recyclePage = false),
              onOpen: (ref) {
                setState(() => _recyclePage = false);
                model.openRelated(ref);
              },
            );
          }
          if (_reading) {
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: bounds.maxWidth.clamp(0, 1100).toDouble(),
                height: bounds.maxHeight,
                child: _detail(context, metrics),
              ),
            );
          }
          return Row(
            key: const ValueKey('library-workspace'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _side(context, metrics),
              _results(context, metrics),
              Expanded(child: _detail(context, metrics)),
            ],
          );
        },
      ),
    ),
  );
}
