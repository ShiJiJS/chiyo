import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'information_editor.dart';
export 'information_editor.dart';
import 'organization.dart';
import 'anchored_surface.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'recycle.dart';
import 'revisions.dart';
import 'ui.dart';
import 'credential_dialogs.dart';
import 'credential_migration.dart';
import 'information_files.dart';
import 'information_file_summary.dart';

class InformationLibrary extends StatefulWidget {
  const InformationLibrary({
    super.key,
    required this.owner,
    this.refresh,
    this.initialDirectoryId,
    this.initialItemId,
    this.onMigrateSecretFields,
    this.onOpenCredentials,
    this.onOpenCredential,
    this.files = const NativeInformationFilePicker(),
  });
  final OwnerAccess owner;
  final Listenable? refresh;
  final String? initialDirectoryId, initialItemId;
  final Future<void> Function(InformationItem item)? onMigrateSecretFields;
  final VoidCallback? onOpenCredentials;
  final ValueChanged<String>? onOpenCredential;
  final InformationFilePicker files;
  @override
  State<InformationLibrary> createState() => _InformationLibraryState();
}

class _InformationLibraryState extends State<InformationLibrary> {
  final _search = TextEditingController();
  final _treeScroll = ScrollController(),
      _listScroll = ScrollController(),
      _detailScroll = ScrollController();
  final _collapsed = <String>{}, _tagIds = <String>{};
  String? _directoryId, _selectedId;
  bool _descendants = true;
  bool _unclassified = false, _sortDescending = false;
  String? _filterNotice;
  bool _focusMissing = false;
  int _offset = 0;
  String? _queryError;
  InformationAttachmentRef? _exportingFile;
  static const _limit = 50;
  OwnerAccess get owner => widget.owner;
  UiPalette get p => UiPalette.of(context);
  @override
  void initState() {
    super.initState();
    _directoryId = widget.initialDirectoryId;
    _selectedId = widget.initialItemId;
    _focusMissing =
        _selectedId != null &&
        !owner.information.any((i) => i.id == _selectedId);
    if (owner.serviceAvailable && _selectedId != null && !_focusMissing) {
      _offset = owner
          .queryInformation(
            directoryId: _directoryId,
            focusItemId: _selectedId,
            limit: _limit,
          )
          .offset;
    }
    widget.refresh?.addListener(_refresh);
  }

  @override
  void didUpdateWidget(InformationLibrary old) {
    super.didUpdateWidget(old);
    if (old.refresh != widget.refresh) {
      old.refresh?.removeListener(_refresh);
      widget.refresh?.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_refresh);
    _search.dispose();
    _treeScroll.dispose();
    _listScroll.dispose();
    _detailScroll.dispose();
    super.dispose();
  }

  void _filter({
    String? directory,
    bool all = false,
    bool unclassified = false,
  }) {
    setState(() {
      _focusMissing = false;
      _directoryId = directory;
      _unclassified = unclassified;
      _filterNotice = null;
      _offset = 0;
      _selectedId = null;
      if (all) {
        _tagIds.clear();
        _search.clear();
      }
    });
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
  }

  Future<void> _edit([InformationItem? item]) async {
    InformationItem? saved;
    try {
      saved = await showOwnerInformationEditor(
        context,
        owner: owner,
        files: widget.files,
        draft: InformationEditorDraft(
          original: item,
          directoryId: item?.directoryId ?? _directoryId,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('编辑器未能完成清理，请重新打开后重试。')));
      }
    }
    if (mounted) {
      setState(() {
        if (saved != null) {
          _focusMissing = false;
          _directoryId = null;
          _unclassified = false;
          _tagIds.clear();
          _search.clear();
          _selectedId = saved.id;
          _offset = owner
              .queryInformation(focusItemId: saved.id, limit: _limit)
              .offset;
        }
      });
    }
  }

  Future<void> _delete(InformationItem item) async {
    await confirmInformationDeletion(context, owner, item);
    _refresh();
  }

  Future<void> _exportFile(InformationAttachmentVersion version) async {
    if (_exportingFile != null) return;
    setState(() => _exportingFile = version.reference);
    try {
      final path = await widget.files.saveAs(version.originalName);
      if (path == null) return;
      await owner.exportInformationFile(version.reference, path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件已另存，副本由你自行保管，不随授权到期删除。')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(informationFileError(error))));
      }
    } finally {
      if (mounted) setState(() => _exportingFile = null);
    }
  }

  Future<void> _history(InformationItem item) async {
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (_) =>
          RevisionHistoryPage(owner: owner, itemId: item.id, asDialog: true),
    );
    _refresh();
  }

  Text t(
    String value,
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    String? family,
    int? lines,
  }) => Text(
    value,
    maxLines: lines,
    overflow: lines == null ? null : TextOverflow.ellipsis,
    style: prototypeText(
      context,
      size,
      color: color,
      weight: weight,
      height: height,
      family: family,
    ),
  );
  Widget b(
    String title,
    VoidCallback? action, {
    Key? key,
    bool border = false,
    double size = 12,
    PrototypeIconGlyph? icon,
  }) => TextButton(
    key: key,
    onPressed: action,
    style: prototypeButton(
      context,
      size: size,
      foreground: p.ink,
      padding: border
          ? const EdgeInsets.symmetric(horizontal: 13, vertical: 8)
          : EdgeInsets.zero,
      side: border ? BorderSide(color: p.line) : BorderSide.none,
      radius: 5,
      background: border ? p.paper : null,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          PrototypeIcon(icon, size: 15),
          const SizedBox(width: 7),
        ],
        Flexible(child: Text(title)),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    InformationPage page;
    try {
      if (_directoryId != null &&
          !owner.directories.any((d) => d.id == _directoryId)) {
        _directoryId = null;
        _selectedId = null;
        _offset = 0;
        _filterNotice = '原目录已删除，已返回全部信息。';
      }
      if (_tagIds.any((id) => !owner.tags.any((t) => t.id == id))) {
        _selectedId = null;
        _offset = 0;
        _filterNotice = '已移除失效的标签筛选。';
      }
      _tagIds.removeWhere((id) => !owner.tags.any((t) => t.id == id));
      page = owner.queryInformation(
        search: _search.text,
        directoryId: _directoryId,
        tagIds: _tagIds,
        includeDescendants: _descendants,
        unclassifiedOnly: _unclassified,
        sortDescending: _sortDescending,
        offset: _offset,
        limit: _limit,
        focusItemId: _selectedId,
      );
      _queryError = null;
      _offset = page.offset;
    } catch (_) {
      _queryError = '信息库查询失败，请检查筛选条件或服务状态后重试。';
      page = InformationPage(const [], 0, 0, _limit);
    }
    final current = _focusMissing
        ? null
        : page.items.where((i) => i.id == _selectedId).firstOrNull ??
              page.items.firstOrNull;
    _selectedId = current?.id;
    return Material(
      color: p.canvas,
      child: LayoutBuilder(
        builder: (context, bounds) => bounds.maxWidth < 940
            ? SingleChildScrollView(
                primary: false,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 940,
                  height: bounds.maxHeight,
                  child: _columns(page, current),
                ),
              )
            : _columns(page, current),
      ),
    );
  }

  Widget _columns(InformationPage page, InformationItem? current) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(width: 240, child: _directory()),
      SizedBox(width: 340, child: _list(page, current)),
      Expanded(child: _detail(current)),
    ],
  );
  Future<void> _directoryAction(
    InformationDirectory directory,
    DirectoryOperation operation,
  ) async {
    final result = await editDirectory(
      context,
      owner,
      directory: operation == DirectoryOperation.create ? null : directory,
      parentId: operation == DirectoryOperation.create ? directory.id : null,
      operation: operation,
    );
    if (!mounted || result == null) return;
    if (operation == DirectoryOperation.delete) {
      _filter(directory: result.isEmpty ? null : result);
    } else {
      final seen = <String>{};
      String? id = result;
      while (id != null && seen.add(id)) {
        _collapsed.remove(id);
        id = owner.directories.where((d) => d.id == id).firstOrNull?.parentId;
      }
      _filter(directory: result);
    }
  }

  Future<void> _filterTags() async {
    var selected = {..._tagIds};
    final result = await showDialog<Object>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PrototypeDialog(
          title: '筛选标签',
          onClose: () => Navigator.pop(dialogContext),
          body: SizedBox(
            height: 320,
            child: TagPicker(
              tags: owner.tags,
              selected: selected,
              count: (id) =>
                  owner.information.where((i) => i.tagIds.contains(id)).length,
              onChanged: (ids) => update(() => selected = ids),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'manage'),
              child: const Text('管理标签'),
            ),
            TextButton(
              onPressed: () => update(() => selected = {}),
              child: const Text('清除标签'),
            ),
            TextButton(
              style: prototypeSecondary(context),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              style: prototypePrimary(context),
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('使用所选标签'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (result == 'manage') {
      await manageTags(context, owner);
      _refresh();
    } else if (result is Set<String>) {
      setState(() {
        _tagIds
          ..clear()
          ..addAll(result);
        _offset = 0;
        _selectedId = null;
      });
    }
  }

  Widget _directory() => Container(
    key: const ValueKey('library-directory'),
    decoration: BoxDecoration(
      color: p.canvas,
      border: Border(right: BorderSide(color: p.line)),
    ),
    padding: const EdgeInsets.fromLTRB(14, 25, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: t('信息库', 21, weight: FontWeight.w600),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  style: prototypeButton(
                    context,
                    size: 13,
                    background: p.paper,
                    foreground: p.strong,
                  ),
                  onPressed: () {},
                  child: const Text('信息'),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextButton(
                  key: const ValueKey('library-credentials-mode'),
                  style: prototypeButton(context, size: 13),
                  onPressed: widget.onOpenCredentials,
                  child: const Text('凭据'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _root(
          '全部信息',
          '${owner.information.length}',
          _directoryId == null && !_unclassified,
          () => _filter(all: true),
        ),
        const SizedBox(height: 3),
        _root(
          '未分类',
          '${owner.information.where((i) => i.directoryId == null).length}',
          _unclassified,
          () => _filter(unclassified: true),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const SizedBox(width: 8),
            Expanded(child: t('目录', 12, color: p.muted)),
            IconButton(
              key: const ValueKey('new-directory'),
              tooltip: '新建目录',
              icon: const Icon(Icons.add, size: 18),
              onPressed: () async {
                final id = await editDirectory(context, owner);
                if (mounted && id != null) _filter(directory: id);
              },
            ),
          ],
        ),
        Expanded(
          child: ListView(
            primary: false,
            controller: _treeScroll,
            padding: EdgeInsets.zero,
            children: [
              ..._branches(null, 0, <String>{}),
              if (owner.directories.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: t('还没有目录', 13, color: p.muted),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.line)),
          ),
          child: b('回收站', () async {
            await showDialog<void>(
              context: context,
              barrierColor: const Color(0x4f241b27),
              builder: (_) => RecyclePage(owner: owner, asDialog: true),
            );
            _refresh();
          }, icon: PrototypeIconGlyph.folder),
        ),
      ],
    ),
  );

  Widget _root(
    String title,
    String count,
    bool selected,
    VoidCallback action,
  ) => TextButton(
    style: prototypeButton(
      context,
      size: 13,
      foreground: p.ink,
      background: selected ? p.selected : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      radius: 6,
    ),
    onPressed: action,
    child: Row(
      children: [
        Expanded(child: Text(title)),
        t(count, 13, color: p.muted, family: 'Georgia'),
      ],
    ),
  );

  List<Widget> _branches(String? parent, int depth, Set<String> visited) => [
    for (final d in owner.directories.where(
      (d) => d.parentId == parent && !visited.contains(d.id),
    )) ...[
      Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Material(
          color: _directoryId == d.id ? p.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            key: ValueKey('directory-${d.id}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => _filter(directory: d.id),
            child: Padding(
              padding: EdgeInsets.only(left: depth * 12.0),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 34,
                    child: owner.directories.any((c) => c.parentId == d.id)
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '展开或收起${d.name}',
                            icon: Icon(
                              _collapsed.contains(d.id)
                                  ? Icons.chevron_right
                                  : Icons.expand_more,
                              size: 16,
                            ),
                            onPressed: () => setState(
                              () => _collapsed.contains(d.id)
                                  ? _collapsed.remove(d.id)
                                  : _collapsed.add(d.id),
                            ),
                          )
                        : null,
                  ),
                  const PrototypeIcon(PrototypeIconGlyph.folder, size: 15),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Tooltip(
                        message: directoryPath(owner, d.id),
                        child: t(
                          d.name,
                          13,
                          lines: 1,
                          weight: _directoryId == d.id
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  t(
                    _directoryCount(d.id),
                    12,
                    color: p.muted,
                    family: 'Georgia',
                  ),
                  Builder(
                    builder: (anchor) => TextButton(
                      key: ValueKey('directory-menu-${d.id}'),
                      style: prototypeButton(
                        context,
                        size: 13,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                      ),
                      onPressed: () async {
                        final action =
                            await showAnchoredSurface<DirectoryOperation>(
                              anchor,
                              width: 180,
                              height: 190,
                              builder: (popup) => ListView(
                                primary: false,
                                padding: const EdgeInsets.all(6),
                                children: [
                                  for (final op in DirectoryOperation.values)
                                    TextButton(
                                      style: prototypeButton(popup, size: 13),
                                      onPressed: () => Navigator.pop(popup, op),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(switch (op) {
                                          DirectoryOperation.create => '新建子目录',
                                          DirectoryOperation.rename => '重命名',
                                          DirectoryOperation.move => '移动',
                                          DirectoryOperation.delete => '删除',
                                        }),
                                      ),
                                    ),
                                ],
                              ),
                            );
                        if (action != null && mounted) {
                          await _directoryAction(d, action);
                        }
                      },
                      child: Icon(
                        Icons.more_horiz,
                        size: 16,
                        semanticLabel: '${d.name}的操作',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (!_collapsed.contains(d.id))
        ..._branches(d.id, depth + 1, {...visited, d.id}),
    ],
  ];

  Widget _listHeader(InformationPage page, InformationDirectory? directory) {
    final scope = _unclassified ? '未分类' : directory?.name ?? '全部信息';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 25, 20, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: t(scope, 18, weight: FontWeight.w700, lines: 2)),
              const SizedBox(width: 8),
              b(
                '＋ 新建',
                _edit,
                key: const ValueKey('new-information'),
                border: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          t(
            '${page.total} 条信息${directory != null && _descendants ? ' · 包含下级目录' : ''}',
            12,
            color: p.muted,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('library-search'),
            controller: _search,
            style: prototypeText(context, 13),
            decoration: InputDecoration(
              hintText: '搜索$scope',
              prefixIcon: const Icon(Icons.search, size: 16),
            ),
            onChanged: (_) => setState(() {
              _offset = 0;
              _selectedId = null;
              _focusMissing = false;
            }),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                key: const ValueKey('library-tag-filter'),
                onPressed: _filterTags,
                style: prototypeButton(
                  context,
                  foreground: p.ink,
                  background: p.paper,
                  side: BorderSide(color: p.line),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('标签${_tagIds.isEmpty ? '' : ' ${_tagIds.length}'}'),
                    const SizedBox(width: 7),
                    const RotatedBox(
                      quarterTurns: 1,
                      child: PrototypeIcon(PrototypeIconGlyph.chev, size: 12),
                    ),
                  ],
                ),
              ),
              b(
                _sortDescending ? '名称 ↓' : '名称 ↑',
                () => setState(() {
                  _sortDescending = !_sortDescending;
                  _offset = 0;
                  _selectedId = null;
                }),
                border: true,
              ),
              if (directory != null || _unclassified)
                b('在全部信息中搜索', () => _filter()),
            ],
          ),
          if (directory != null)
            Row(
              children: [
                Checkbox(
                  value: _descendants,
                  onChanged: (value) => setState(() {
                    _descendants = value!;
                    _offset = 0;
                    _selectedId = null;
                  }),
                ),
                Flexible(child: t('包含下级目录', 12, color: p.muted)),
              ],
            ),
          if (_tagIds.isNotEmpty || _search.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 100),
                child: SingleChildScrollView(
                  primary: false,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final tag in owner.tags.where(
                        (t) => _tagIds.contains(t.id),
                      ))
                        b(
                          '${tag.name} ×',
                          () => setState(() {
                            _tagIds.remove(tag.id);
                            _offset = 0;
                            _selectedId = null;
                          }),
                          border: true,
                        ),
                      b(
                        '清除筛选',
                        () => setState(() {
                          _tagIds.clear();
                          _search.clear();
                          _offset = 0;
                          _selectedId = null;
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_filterNotice != null)
            Row(
              children: [
                Expanded(child: t(_filterNotice!, 12, color: p.muted)),
                IconButton(
                  onPressed: () => setState(() => _filterNotice = null),
                  tooltip: '关闭筛选提示',
                  icon: const Icon(Icons.close, size: 15),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _list(InformationPage page, InformationItem? current) {
    final directory = owner.directories
        .where((d) => d.id == _directoryId)
        .firstOrNull;
    return Container(
      key: const ValueKey('library-list'),
      decoration: BoxDecoration(
        color: p.rail,
        border: Border(right: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _listHeader(page, directory),
          Expanded(
            child: page.items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          t(
                            _queryError ?? '没有匹配的信息',
                            16,
                            color: _queryError == null ? null : p.danger,
                          ),
                          const SizedBox(height: 12),
                          t(
                            _queryError == null
                                ? '试试其他关键词或目录。'
                                : '筛选条件已保留，可调整后重试。',
                            12,
                            color: p.muted,
                          ),
                          const SizedBox(height: 16),
                          b('查看全部', () => _filter(all: true), border: true),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    primary: false,
                    key: const ValueKey('library-item-scroll'),
                    controller: _listScroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    itemCount: page.items.length,
                    itemBuilder: (context, index) {
                      final item = page.items[index];
                      final selected = item.id == current?.id;
                      return TextButton(
                        key: ValueKey(item.id),
                        style: prototypeButton(
                          context,
                          foreground: p.ink,
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: () => setState(() {
                          _focusMissing = false;
                          _selectedId = item.id;
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: selected ? p.selected : null,
                            border: Border.all(
                              color: selected
                                  ? Color.lerp(p.line, p.accent, .25)!
                                  : Colors.transparent,
                            ),
                            borderRadius: BorderRadius.circular(
                              selected ? 6 : 0,
                            ),
                          ),
                          foregroundDecoration: selected
                              ? null
                              : BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: p.line),
                                  ),
                                ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _itemIcon(item, 33, 35),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    t(
                                      item.name,
                                      14,
                                      weight: FontWeight.w700,
                                      height: 1.6,
                                      lines: 2,
                                    ),
                                    const SizedBox(height: 5),
                                    t(
                                      item.description,
                                      12,
                                      color: p.muted,
                                      lines: 1,
                                    ),
                                    const SizedBox(height: 11),
                                    Row(
                                      children: [
                                        Flexible(
                                          child: t(
                                            owner.directories
                                                    .where(
                                                      (d) =>
                                                          d.id ==
                                                          item.directoryId,
                                                    )
                                                    .firstOrNull
                                                    ?.name ??
                                                '未分类',
                                            11,
                                            color: p.muted,
                                            lines: 1,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        t(
                                          '${item.fields.length} 个字段${item.fields.any((f) => f.kind == FieldKind.file) ? ' · 含文件' : ''}',
                                          11,
                                          color: p.muted,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Padding(
                                padding: const EdgeInsets.only(top: 30),
                                child: PrototypeIcon(
                                  PrototypeIconGlyph.chev,
                                  size: 13,
                                  color: p.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.line)),
            ),
            child: Row(
              children: [
                t('共 ${page.total} 条信息', 11, color: p.muted),
                const Spacer(),
                b(
                  '‹',
                  page.offset > 0
                      ? () => setState(() {
                          _offset = page.offset - _limit;
                          _selectedId = null;
                        })
                      : null,
                ),
                const SizedBox(width: 12),
                t(
                  '${page.offset ~/ page.limit + 1} / ${page.total == 0 ? 1 : (page.total / page.limit).ceil()}',
                  12,
                  color: p.strong,
                  family: 'Georgia',
                ),
                const SizedBox(width: 12),
                b(
                  '›',
                  page.offset + page.items.length < page.total
                      ? () => setState(() {
                          _offset = page.offset + _limit;
                          _selectedId = null;
                        })
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _directoryCount(String id) {
    try {
      return '${owner.queryInformation(directoryId: id, limit: 1).total}';
    } catch (_) {
      return '—';
    }
  }

  PrototypeIconGlyph _glyph(InformationItem item) =>
      item.fields.any(
        (f) => f.kind != FieldKind.file && f.value.startsWith('http'),
      )
      ? PrototypeIconGlyph.link
      : PrototypeIconGlyph.file;
  Widget _itemIcon(
    InformationItem item,
    double width,
    double height, {
    bool large = false,
  }) => Container(
    width: width,
    height: height,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: large ? p.selected : p.paper,
      border: large ? null : Border.all(color: p.line),
      borderRadius: BorderRadius.circular(large ? 9 : 5),
    ),
    child: PrototypeIcon(_glyph(item), size: large ? 24 : 18, color: p.strong),
  );
  Widget _detail(InformationItem? item) => Padding(
    key: const ValueKey('library-detail'),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 21),
    child: Container(
      decoration: BoxDecoration(
        color: p.paper,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(9),
      ),
      clipBehavior: Clip.antiAlias,
      child: item == null
          ? Center(
              child: t(
                _focusMissing ? '当前信息已不存在，请重新选择或检查回收站。' : '请选择一条信息',
                16,
                color: p.muted,
              ),
            )
          : Column(
              key: ValueKey('information-${item.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 55),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.line)),
                  ),
                  child: LayoutBuilder(
                    builder: (context, box) => Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        SizedBox(
                          width: box.maxWidth.clamp(0, 220).toDouble(),
                          child: t(
                            directoryPath(owner, item.directoryId),
                            12,
                            color: p.muted,
                            lines: 2,
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            b(
                              '调整目录与标签',
                              () async {
                                await organizeItem(context, owner, item);
                                _refresh();
                              },
                              key: const ValueKey('edit-information-category'),
                            ),
                            b(
                              '编辑',
                              () => _edit(item),
                              key: const ValueKey(
                                'edit-information-description',
                              ),
                              icon: PrototypeIconGlyph.edit,
                            ),
                            b('移入回收站', () => _delete(item)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    primary: false,
                    controller: _detailScroll,
                    padding: const EdgeInsets.fromLTRB(33, 23, 33, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _itemIcon(item, 47, 49, large: true),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  t(
                                    item.name,
                                    26,
                                    weight: FontWeight.w700,
                                    height: 1.4,
                                  ),
                                  const SizedBox(height: 7),
                                  t(
                                    item.description,
                                    13,
                                    height: 1.8,
                                    color: p.muted,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 22),
                          padding: const EdgeInsets.symmetric(vertical: 17),
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: p.line),
                              bottom: BorderSide(color: p.line),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 15,
                                child: _property(
                                  '所在位置',
                                  t(directoryPath(owner, item.directoryId), 12),
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                flex: 7,
                                child: _property(
                                  '标签',
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 5,
                                    children: [
                                      for (final tag in owner.tags.where(
                                        (tag) => item.tagIds.contains(tag.id),
                                      ))
                                        _tag(tag.name),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                flex: 10,
                                child: _property(
                                  '最近更新',
                                  t(_date(item.modifiedAt), 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            t('信息内容', 16, weight: FontWeight.w700),
                            const Spacer(),
                            t('${item.fields.length} 个字段', 11, color: p.muted),
                          ],
                        ),
                        const SizedBox(height: 6),
                        for (final field in item.fields)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 17),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: p.line)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 155,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      t(
                                        field.name,
                                        13,
                                        weight: FontWeight.w500,
                                      ),
                                      const SizedBox(height: 6),
                                      t(field.description, 11, color: p.muted),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 1),
                                    child: field.kind == FieldKind.file
                                        ? InformationFileSummary(
                                            owner: owner,
                                            reference: field.attachment!,
                                            actions: (version) => Wrap(
                                              spacing: 12,
                                              runSpacing: 4,
                                              children: [
                                                b('更换文件', () => _edit(item)),
                                                b(
                                                  '另存',
                                                  version.available &&
                                                          _exportingFile == null
                                                      ? () =>
                                                            _exportFile(version)
                                                      : null,
                                                  key: ValueKey(
                                                    'export-file-${field.id}',
                                                  ),
                                                ),
                                                b('公开预览', () => _catalog(item)),
                                              ],
                                            ),
                                          )
                                        : SelectableText(
                                            field.value,
                                            style: prototypeText(
                                              context,
                                              13,
                                              family: 'Consolas',
                                              height: 1.6,
                                            ),
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Container(
                          margin: const EdgeInsets.only(top: 24),
                          padding: const EdgeInsets.only(top: 20),
                          decoration: BoxDecoration(
                            border: Border(top: BorderSide(color: p.line)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  t('关联凭据', 16, weight: FontWeight.w700),
                                  const Spacer(),
                                  b(
                                    '管理关联',
                                    () async {
                                      await manageCredentialLinks(
                                        context,
                                        owner,
                                        item,
                                      );
                                      _refresh();
                                    },
                                    border: true,
                                    icon: PrototypeIconGlyph.link,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              t(
                                '凭据单独保管；批准读取这条信息不会同时提供凭据。',
                                12,
                                height: 1.8,
                                color: p.muted,
                              ),
                              const SizedBox(height: 13),
                              if (owner
                                  .credentialsForInformation(item.id)
                                  .isEmpty)
                                t('尚未关联凭据', 13, color: p.muted),
                              for (final c in owner.credentialsForInformation(
                                item.id,
                              ))
                                TextButton(
                                  onPressed: widget.onOpenCredential == null
                                      ? null
                                      : () => widget.onOpenCredential!(c.id),
                                  style: prototypeButton(
                                    context,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 13,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const PrototypeIcon(
                                        PrototypeIconGlyph.key,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            t(
                                              c.name,
                                              14,
                                              weight: FontWeight.w500,
                                            ),
                                            const SizedBox(height: 5),
                                            t(
                                              '${c.publicPurpose} · ${credentialStatus(owner, c)}',
                                              12,
                                              color: p.muted,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const PrototypeIcon(
                                        PrototypeIconGlyph.chev,
                                        size: 13,
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 22),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          color: p.rail,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              PrototypeIcon(
                                PrototypeIconGlyph.shield,
                                color: p.muted,
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    t(
                                      'Agent 能看到什么？',
                                      13,
                                      weight: FontWeight.w500,
                                    ),
                                    const SizedBox(height: 7),
                                    t(
                                      '公开目录包含名称、公开说明及字段说明。字段内容只有在你批准后才能读取。',
                                      12,
                                      height: 1.8,
                                      color: p.muted,
                                    ),
                                    b('预览公开目录', () => _catalog(item), size: 11),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 27,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: p.rail,
                    border: Border(top: BorderSide(color: p.line)),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PrototypeIcon(
                            PrototypeIconGlyph.shield,
                            size: 15,
                            color: p.muted,
                          ),
                          const SizedBox(width: 8),
                          t('按字段授权', 11, color: p.muted),
                        ],
                      ),
                      TextButton(
                        style: prototypeButton(
                          context,
                          size: 13,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          foreground: p.accent,
                        ),
                        onPressed: () => _history(item),
                        child: const Text('修改历史 ↗'),
                      ),
                      TextButton(
                        style: prototypeButton(
                          context,
                          size: 13,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          foreground: p.accent,
                        ),
                        onPressed: () async {
                          final migrate = widget.onMigrateSecretFields;
                          if (migrate != null) {
                            await migrate(item);
                            _refresh();
                            return;
                          }
                          if (!context.mounted) return;
                          final credential =
                              await showDialog<ManagedCredential>(
                                context: context,
                                barrierDismissible: false,
                                barrierColor: const Color(0x4f241b27),
                                builder: (_) => CredentialMigrationDialog(
                                  owner: owner,
                                  item: item,
                                ),
                              );
                          _refresh();
                          if (mounted && credential != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('已建立托管凭据并关闭旧读取路径。旧授权不会恢复。'),
                                action: widget.onOpenCredential == null
                                    ? null
                                    : SnackBarAction(
                                        label: '查看凭据',
                                        onPressed: () =>
                                            widget.onOpenCredential!(
                                              credential.id,
                                            ),
                                      ),
                              ),
                            );
                          }
                        },
                        child: const Text('转换旧秘密字段'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
  Widget _property(String title, Widget value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      t(title, 11, color: p.muted),
      const SizedBox(height: 8),
      value,
    ],
  );
  Widget _tag(String title) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(4),
    ),
    child: t(title, 11, color: p.muted),
  );
  String _date(DateTime? date) {
    if (date == null) return '时间未知';
    final local = date.toLocal(), now = DateTime.now();
    final day =
        local.year == now.year &&
            local.month == now.month &&
            local.day == now.day
        ? '今天'
        : '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    return '$day ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _catalog(InformationItem item) => showDialog<void>(
    context: context,
    barrierColor: const Color(0x4f241b27),
    builder: (_) => PrototypeDialog(
      title: 'Agent 可见的公开目录',
      onClose: () => Navigator.pop(context),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          t(item.name, 16, weight: FontWeight.w600),
          t(item.description, 14),
          for (final field in item.fields)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  t(field.name, 13, weight: FontWeight.w500),
                  t(field.description, 12),
                  if (field.kind == FieldKind.file) t('文件', 12, color: p.muted),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
