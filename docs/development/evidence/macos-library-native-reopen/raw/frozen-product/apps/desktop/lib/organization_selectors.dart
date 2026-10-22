import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'anchored_surface.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

String organizationPath(List<InformationDirectory> directories, String? id) {
  final names = <String>[], seen = <String>{};
  while (id != null && seen.add(id)) {
    final found = directories.where((d) => d.id == id).firstOrNull;
    if (found == null) break;
    names.insert(0, found.name);
    id = found.parentId;
  }
  return names.isEmpty ? '未分类' : names.join(' / ');
}

class DirectorySelection {
  const DirectorySelection(this.id);
  final String? id;
}

class DirectoryTreePicker extends StatefulWidget {
  const DirectoryTreePicker({
    super.key,
    required this.directories,
    required this.onSelected,
    this.selected,
    this.excludeId,
    this.rootLabel = '未分类',
  });
  final List<InformationDirectory> directories;
  final String? selected, excludeId;
  final String rootLabel;
  final ValueChanged<String?> onSelected;
  @override
  State<DirectoryTreePicker> createState() => _DirectoryTreePickerState();
}

class _DirectoryTreePickerState extends State<DirectoryTreePicker> {
  String _search = '';
  final _collapsed = <String>{};
  Set<String> get _blocked {
    final result = <String>{if (widget.excludeId != null) widget.excludeId!};
    for (var i = 0; i < widget.directories.length; i++) {
      for (final d in widget.directories) {
        if (result.contains(d.parentId)) result.add(d.id);
      }
    }
    return result;
  }

  List<Widget> _rows(String? parent, int depth, Set<String> seen) => [
    for (final d in widget.directories.where(
      (d) => d.parentId == parent && !seen.contains(d.id),
    )) ...[
      if (_search.isEmpty ||
          organizationPath(
            widget.directories,
            d.id,
          ).toLowerCase().contains(_search.toLowerCase()))
        Row(
          children: [
            SizedBox(width: _search.isEmpty ? depth * 12 : 0),
            SizedBox(
              width: 26,
              child: widget.directories.any((c) => c.parentId == d.id)
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _collapsed.contains(d.id)
                            ? Icons.chevron_right
                            : Icons.expand_more,
                        size: 16,
                      ),
                      tooltip: '展开或收起${d.name}',
                      onPressed: () => setState(
                        () => _collapsed.contains(d.id)
                            ? _collapsed.remove(d.id)
                            : _collapsed.add(d.id),
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: TextButton(
                style: prototypeButton(
                  context,
                  foreground: UiPalette.of(context).ink,
                  background: widget.selected == d.id
                      ? UiPalette.of(context).selected
                      : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 9,
                  ),
                ),
                onPressed: _blocked.contains(d.id)
                    ? null
                    : () => widget.onSelected(d.id),
                child: Row(
                  children: [
                    const PrototypeIcon(PrototypeIconGlyph.folder, size: 15),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _search.isEmpty
                            ? d.name
                            : organizationPath(widget.directories, d.id),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_blocked.contains(d.id))
                      const Text('不可移入', style: TextStyle(fontSize: 11)),
                    if (widget.selected == d.id)
                      const Icon(Icons.check, size: 15),
                  ],
                ),
              ),
            ),
          ],
        ),
      if (!_collapsed.contains(d.id) || _search.isNotEmpty)
        ..._rows(d.id, depth + 1, {...seen, d.id}),
    ],
  ];
  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(
        decoration: const InputDecoration(
          hintText: '搜索目录',
          prefixIcon: Icon(Icons.search, size: 17),
        ),
        onChanged: (v) => setState(() => _search = v),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          primary: false,
          children: [
            TextButton(
              style: prototypeButton(
                context,
                background: widget.selected == null
                    ? UiPalette.of(context).selected
                    : null,
              ),
              onPressed: () => widget.onSelected(null),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.rootLabel),
              ),
            ),
            ..._rows(null, 0, <String>{}),
          ],
        ),
      ),
    ],
  );
}

class DirectoryField extends StatelessWidget {
  const DirectoryField({
    super.key,
    required this.directories,
    required this.onChanged,
    this.value,
    this.enabled = true,
  });
  final List<InformationDirectory> directories;
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => OutlinedButton(
      style: prototypeButton(
        context,
        foreground: UiPalette.of(context).ink,
        side: BorderSide(color: UiPalette.of(context).line),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      ),
      onPressed: !enabled
          ? null
          : () async {
              final result = await showAnchoredSurface<DirectorySelection>(
                anchor,
                width: 340,
                height: 330,
                builder: (popup) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: DirectoryTreePicker(
                    directories: directories,
                    selected: value,
                    onSelected: (id) =>
                        Navigator.pop(popup, DirectorySelection(id)),
                  ),
                ),
              );
              if (result != null && context.mounted) onChanged(result.id);
            },
      child: Row(
        children: [
          Expanded(
            child: Text(
              value != null && !directories.any((d) => d.id == value)
                  ? '原目录不可用，请重新选择'
                  : organizationPath(directories, value),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.expand_more, size: 16),
        ],
      ),
    ),
  );
}

class TagPicker extends StatefulWidget {
  const TagPicker({
    super.key,
    required this.tags,
    required this.selected,
    required this.onChanged,
    this.count,
  });
  final List<InformationTag> tags;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final int Function(String)? count;
  @override
  State<TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<TagPicker> {
  String _search = '';
  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(
        decoration: const InputDecoration(
          hintText: '搜索标签',
          prefixIcon: Icon(Icons.search, size: 17),
        ),
        onChanged: (v) => setState(() => _search = v),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          primary: false,
          children: [
            for (final tag in widget.tags.where(
              (t) => t.name.toLowerCase().contains(_search.toLowerCase()),
            ))
              CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                title: Text(tag.name),
                value: widget.selected.contains(tag.id),
                secondary: widget.count == null
                    ? null
                    : Text(
                        '${widget.count!(tag.id)} 条',
                        style: prototypeText(
                          context,
                          12,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                onChanged: (checked) {
                  final next = {...widget.selected};
                  checked == true ? next.add(tag.id) : next.remove(tag.id);
                  widget.onChanged(next);
                },
              ),
            if (widget.tags.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('还没有标签，可在标签管理中创建。'),
              ),
          ],
        ),
      ),
    ],
  );
}
