import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../desktop_motion.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'classification_controller.dart';
import 'library_directory_dialog.dart';
import 'library_widgets.dart';
import 'settings_layout.dart';
import 'workspace_source.dart';

class ClassificationPage extends StatefulWidget {
  const ClassificationPage({
    super.key,
    required this.controller,
    this.onModalChanged,
  });
  final ClassificationController controller;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<ClassificationPage> createState() => _ClassificationPageState();
}

class _ClassificationPageState extends State<ClassificationPage> {
  ClassificationController get m => widget.controller;
  late final TextEditingController _search;
  late final ScrollController _scroll;
  late (WorkspaceClassificationKind, String, int) _view;
  @override
  void initState() {
    super.initState();
    _view = (m.kind, m.keyword, m.offset);
    _scroll = ScrollController(initialScrollOffset: m.scrollOffset)
      ..addListener(() {
        if (_scroll.hasClients) m.scrollOffset = _scroll.offset;
      });
    _search = TextEditingController(text: m.keyword);
    m.addListener(_changed);
    if (m.catalog == null) unawaited(m.load());
  }

  void _changed() {
    if (_search.text != m.keyword) _search.text = m.keyword;
    final next = (m.kind, m.keyword, m.offset);
    if (next != _view) {
      _view = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            m.scrollOffset.clamp(0, _scroll.position.maxScrollExtent),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _edit(String action, {String? id, String? parent}) async {
    final c = m.catalog;
    if (c == null || m.loading || m.failure != null) return;
    widget.onModalChanged?.call(true);
    try {
      final receipt = await showClassificationEditor(
        context,
        m.source,
        c,
        kind: m.kind,
        action: action,
        directory: m.kind == WorkspaceClassificationKind.directory
            ? c.directories.where((d) => d.id == id).firstOrNull
            : null,
        tag: m.kind == WorkspaceClassificationKind.tag
            ? c.tags.where((t) => t.id == id).firstOrNull
            : null,
        initialParent: parent,
      );
      if (!mounted || receipt == null) return;
      await m.load(reveal: action == 'delete' ? null : receipt.targetId);
      if (mounted && action != 'delete') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _rowKeys[_rowKey(receipt.targetId)]?.currentContext;
          if (mounted && target != null) {
            Scrollable.ensureVisible(
              target,
              alignment: 0.15,
              duration: const Duration(milliseconds: 180),
            );
          }
        });
      }
      if (mounted) {
        DesktopFeedback.show(
          context,
          action == 'delete'
              ? '已删除${m.kind == WorkspaceClassificationKind.tag ? '标签标记' : '空目录'}'
              : '分类已保存',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  final _rowKeys = <String, GlobalKey>{};
  String _rowKey(String id) => '${m.kind.name}:$id';
  Widget _row(
    BuildContext context,
    WorkspaceClassificationRow row,
    bool large,
  ) {
    final c = UiPalette.of(context),
        tag = m.kind == WorkspaceClassificationKind.tag,
        enabled = !m.loading && m.failure == null;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.name,
          style: libraryText(context, 16, weight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Text(
          tag ? '${row.count} 条资料或凭据' : '${row.path} · ${row.count} 条资料或凭据',
          style: libraryText(context, 13, color: c.muted, height: 1.7),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!tag)
          DesktopButton(
            key: ValueKey('classification-child-${row.id}'),
            onPressed: enabled ? () => _edit('create', parent: row.id) : null,
            child: const Text('新建子目录'),
          ),
        DesktopButton(
          key: ValueKey('classification-edit-${row.id}'),
          onPressed: enabled ? () => _edit('update', id: row.id) : null,
          child: Text(tag ? '重命名' : '重命名或移动'),
        ),
        DesktopButton(
          key: ValueKey('classification-delete-${row.id}'),
          onPressed: enabled ? () => _edit('delete', id: row.id) : null,
          child: const Text('删除'),
        ),
      ],
    );
    return KeyedSubtree(
      key: _rowKeys.putIfAbsent(_rowKey(row.id), () => GlobalKey()),
      child: Container(
        key: ValueKey('classification-row-${row.id}'),
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: large
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, const SizedBox(height: 14), actions],
              )
            : Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 18),
                  actions,
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final c = UiPalette.of(context),
          tag = m.kind == WorkspaceClassificationKind.tag,
          large = MediaQuery.textScalerOf(context).scale(1) >= 1.6,
          rows = m.rows;
      final keys = rows.map((r) => _rowKey(r.id)).toSet();
      _rowKeys.removeWhere((key, _) => !keys.contains(key));
      final header = <Widget>[
        SettingsPageHeading(
          title: '目录与标签',
          description: tag
              ? '标签用于跨目录查找。名称和归属默认对接入的Agent可见；内容仍需单独授权。'
              : '目录整理资料与凭据的层级归属。这里只管理资料分类，不操作本机文件夹。',
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final kind in WorkspaceClassificationKind.values)
              DesktopButton(
                key: ValueKey('classification-kind-${kind.name}'),
                selected: m.kind == kind,
                onPressed: () => m.select(kind),
                child: Text(
                  kind == WorkspaceClassificationKind.tag ? '标签' : '目录',
                ),
              ),
            DesktopButton(
              key: const ValueKey('classification-create'),
              kind: DesktopButtonKind.primary,
              onPressed: m.loading || m.catalog == null || m.failure != null
                  ? null
                  : () => _edit('create'),
              leading: const PrototypeIcon(PrototypeIconGlyph.plus),
              child: Text(tag ? '新建标签' : '新建目录'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        DesktopTextField(
          key: const ValueKey('classification-search'),
          controller: _search,
          onChanged: m.search,
          decoration: InputDecoration(
            labelText: tag ? '查找标签' : '查找目录',
            prefixIcon: const Padding(
              padding: EdgeInsets.all(12),
              child: PrototypeIcon(PrototypeIconGlyph.search),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (m.loading) const LinearProgressIndicator(),
        if (m.failure != null)
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                m.failure!.message,
                style: libraryText(context, 14, color: c.danger),
              ),
              DesktopButton(
                key: const ValueKey('classification-read-retry'),
                onPressed: m.loading ? null : () => m.load(),
                child: const Text('重新读取分类'),
              ),
            ],
          ),
        if (m.notice.isNotEmpty)
          Text(m.notice, style: libraryText(context, 13, color: c.muted)),
        const SizedBox(height: 8),
        Text(
          '${m.total} 个${tag ? '标签' : '目录'}${tag ? ' · 数量为当前资料和凭据' : ' · 资料数量包含下级目录'}',
          style: libraryText(context, 13, color: c.muted),
        ),
        const SizedBox(height: 12),
      ];
      final empty = Center(
        child: Text(
          m.catalog == null
              ? m.loading
                    ? '正在读取分类…'
                    : '分类暂不可用'
              : m.keyword.isEmpty
              ? '还没有${tag ? '标签' : '目录'}，可以从上方新建。'
              : '没有匹配的分类，请调整搜索。',
        ),
      );
      Widget scroll(List<Widget> children) => Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );
      final body = large
          ? scroll([
              ...header,
              if (rows.isEmpty)
                SizedBox(height: 200, child: empty)
              else
                for (final row in rows) _row(context, row, large),
            ])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...header,
                Expanded(
                  child: rows.isEmpty
                      ? empty
                      : scroll([
                          for (final row in rows) _row(context, row, large),
                        ]),
                ),
              ],
            );
      return DesktopEntrance(
        child: Padding(
          // Normal text keeps the header outside the list scroller; reserve
          // ZhiyuApp's 9px lane here so it shares the other settings headings.
          // Large text scrolls the header too, so that scroller owns the lane.
          padding:
              SettingsPageContent.paddingOf(context) +
              EdgeInsets.only(right: large ? 0 : 9),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: large ? 1029 : 1020),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: body),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${m.total == 0 ? 0 : m.offset + 1}–${(m.offset + ClassificationController.limit).clamp(0, m.total)} / ${m.total}',
                        style: libraryText(context, 13, color: c.muted),
                      ),
                      DesktopButton(
                        key: const ValueKey('classification-previous'),
                        onPressed: m.offset == 0
                            ? null
                            : () => m.page(
                                m.offset - ClassificationController.limit,
                              ),
                        child: const Text('上一页'),
                      ),
                      DesktopButton(
                        key: const ValueKey('classification-next'),
                        onPressed:
                            m.offset + ClassificationController.limit >= m.total
                            ? null
                            : () => m.page(
                                m.offset + ClassificationController.limit,
                              ),
                        child: const Text('下一页'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
