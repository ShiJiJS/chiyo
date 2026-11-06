import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import 'workspace_records.dart';
import 'directory_tree.dart';
export 'directory_tree.dart';

class DirectorySelection {
  const DirectorySelection(this.id, {this.proposedPath = ''});
  final String? id;
  final String proposedPath;
}

Future<DirectorySelection?> showDirectoryPicker(
  BuildContext context,
  WorkspaceCatalog catalog, {
  String? selected,
  String? parentFor,
  bool parentMode = false,
  bool readOnly = false,
  bool allowNew = false,
  String initialPath = '',
}) => showDesktopDialog<DirectorySelection>(
  context,
  builder: (_) => _DirectoryPicker(
    catalog,
    selected,
    parentFor,
    parentMode,
    readOnly,
    allowNew,
    initialPath,
  ),
);

class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker(
    this.catalog,
    this.selected,
    this.parentFor,
    this.parentMode,
    this.readOnly,
    this.allowNew,
    this.initialPath,
  );
  final WorkspaceCatalog catalog;
  final String? selected, parentFor;
  final bool parentMode;
  final bool readOnly, allowNew;
  final String initialPath;
  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  final _search = TextEditingController();
  late final _newPath = TextEditingController(text: widget.initialPath);
  String? _pathError;
  bool _editingPath = false;
  String _searchable(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s*/\s*'), '/');
  void _choosePath() {
    final parts = _newPath.text.split('/').map((p) => p.trim()).toList();
    if (_newPath.text.length > 200 ||
        parts.length > 8 ||
        parts.any(
          (p) => p.isEmpty || p == '.' || p == '..' || p.contains('\\'),
        )) {
      setState(() => _pathError = '请填写最多8层的完整路径，用 / 分隔，不能有空层级、反斜线、. 或 ..。');
      return;
    }
    final path = parts.join('/');
    final existing = widget.catalog.directories
        .where(
          (d) =>
              _searchable(directoryPath(widget.catalog, d.id)) ==
              _searchable(path),
        )
        .firstOrNull;
    Navigator.pop(
      context,
      existing == null
          ? DirectorySelection(null, proposedPath: path)
          : DirectorySelection(
              existing.id,
              proposedPath: existing.proposed ? path : '',
            ),
    );
  }

  final _collapsed = <String>{};
  @override
  void dispose() {
    _search.dispose();
    _newPath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchable(_search.text);
    final rows = libraryDirectoryTree(widget.catalog).where((d) {
      if (d.id == 'all' || d.id == 'unfiled') return false;
      final path = libraryDirectoryAncestors(widget.catalog, d);
      if (path.any((p) => p.id == widget.parentFor)) return false;
      if (query.isNotEmpty) {
        return _searchable(directoryPath(widget.catalog, d.id)).contains(query);
      }
      return !path.take(path.length - 1).any((p) => _collapsed.contains(p.id));
    }).toList();
    return DesktopDialog(
      title: Text(widget.readOnly ? '查看目录结构' : '选择目录'),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .52,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(labelText: '搜索目录名称或完整路径'),
              onChanged: (_) => setState(() {}),
            ),
            TextButton(
              onPressed: widget.readOnly
                  ? null
                  : () =>
                        Navigator.pop(context, const DirectorySelection(null)),
              child: Text(widget.parentMode ? '顶层目录' : '未分类'),
            ),
            if (widget.allowNew && !widget.readOnly) ...[
              TextButton.icon(
                onPressed: () => setState(() => _editingPath = !_editingPath),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('调整拟建目录路径'),
              ),
              if (_editingPath) ...[
                TextField(
                  key: const ValueKey('proposed-directory-path'),
                  controller: _newPath,
                  maxLength: 200,
                  decoration: InputDecoration(
                    labelText: '完整路径，例如：账号与服务 / 应用',
                    errorText: _pathError,
                  ),
                  onChanged: (_) => setState(() => _pathError = null),
                  onSubmitted: (_) => _choosePath(),
                ),
                const Text('同一级已有同名目录会复用；新目录随整份提案一起保存。'),
              ],
            ],
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('没有匹配的目录'))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final d = rows[index],
                            path = libraryDirectoryAncestors(
                              widget.catalog,
                              rows[index],
                            );
                        final children = widget.catalog.directories.any(
                          (c) => c.parentId == d.id,
                        );
                        return Padding(
                          padding: EdgeInsets.only(
                            left: query.isEmpty ? (path.length - 1) * 16.0 : 0,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 36,
                                child: children && query.isEmpty
                                    ? IconButton(
                                        tooltip: _collapsed.contains(d.id)
                                            ? '展开${d.name}'
                                            : '收起${d.name}',
                                        onPressed: () => setState(() {
                                          if (!_collapsed.add(d.id)) {
                                            _collapsed.remove(d.id);
                                          }
                                        }),
                                        icon: Icon(
                                          _collapsed.contains(d.id)
                                              ? Icons.chevron_right
                                              : Icons.expand_more,
                                        ),
                                      )
                                    : null,
                              ),
                              Expanded(
                                child: TextButton(
                                  onPressed: widget.readOnly
                                      ? null
                                      : () => Navigator.pop(
                                          context,
                                          DirectorySelection(
                                            d.id,
                                            proposedPath: d.proposed
                                                ? directoryPath(
                                                        widget.catalog,
                                                        d.id,
                                                      )
                                                      .split('/')
                                                      .map((p) => p.trim())
                                                      .join('/')
                                                : '',
                                          ),
                                        ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${d.name}${d.proposed ? ' · 将新建' : ''}${widget.selected == d.id ? ' · 已选' : ''}',
                                        ),
                                        Text(
                                          directoryPath(widget.catalog, d.id),
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_editingPath)
          DesktopButton(onPressed: _choosePath, child: const Text('使用此路径')),
        DesktopButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
