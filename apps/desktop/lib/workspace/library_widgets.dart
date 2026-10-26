import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'workspace_records.dart';

String libraryLocalDateTime(DateTime value) {
  final time = value.toLocal();
  String pair(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${pair(time.month)}-${pair(time.day)} ${pair(time.hour)}:${pair(time.minute)}';
}

/// Final Round09 workspace.css metrics, including the <=1300px overrides.
class LibraryMetrics {
  const LibraryMetrics(this.width);
  final double width;
  bool get compact => width <= 1300;
  double get directoryWidth => compact ? 194 : 214;
  double get resultsWidth => compact ? 275 : 300;
  EdgeInsets get detailMargin => compact
      ? const EdgeInsets.all(10)
      : const EdgeInsets.symmetric(horizontal: 14, vertical: 12);
  EdgeInsets get detailPadding => compact
      ? const EdgeInsets.fromLTRB(23, 23, 23, 40)
      : const EdgeInsets.fromLTRB(29, 27, 29, 45);
  double get toolbarPadding => compact ? 19 : 23;
  double get titleSize => compact ? 24 : 27;
  double get iconSize => compact ? 41 : 47;
  double get headerGap => compact ? 12 : 14;
}

TextStyle libraryText(
  BuildContext context,
  double size, {
  Color? color,
  FontWeight? weight,
  double height = 1.6,
}) => Theme.of(context).textTheme.bodyMedium!.copyWith(
  fontSize: size,
  height: height,
  color: color ?? UiPalette.of(context).ink,
  fontWeight: weight ?? FontWeight.w400,
);

class RecordIcon extends StatelessWidget {
  const RecordIcon(this.type, {super.key, this.size = 33});
  final WorkspaceType type;
  final double size;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final group = switch (type.icon) {
      'layers' || 'globe' => 'green',
      'book' || 'plugin' => 'purple',
      'key' || 'file' => 'amber',
      _ => 'blue',
    };
    final (ink, background) = switch ((group, dark)) {
      ('green', false) => (0xff27765c, 0xffe4f1eb),
      ('green', true) => (0xff8ecfb2, 0xff253c35),
      ('purple', false) => (0xff765b9e, 0xffeee9f7),
      ('purple', true) => (0xffc5afe8, 0xff393149),
      ('amber', false) => (0xff865a20, 0xfff7efdf),
      ('amber', true) => (0xffdfbc7d, 0xff413828),
      (_, true) => (0xffa2bde8, 0xff29394f),
      _ => (0xff456b9e, 0xffe8eef8),
    };
    final glyph = switch (type.icon) {
      'server' => PrototypeIconGlyph.server,
      'layers' => PrototypeIconGlyph.layers,
      'user' => PrototypeIconGlyph.user,
      'book' => PrototypeIconGlyph.book,
      'key' => PrototypeIconGlyph.key,
      'plugin' => PrototypeIconGlyph.plugin,
      'globe' => PrototypeIconGlyph.globe,
      _ => PrototypeIconGlyph.file,
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color(background),
        borderRadius: BorderRadius.circular(10),
      ),
      child: PrototypeIcon(glyph, size: size > 40 ? 23 : 18, color: Color(ink)),
    );
  }
}

class LibraryTag extends StatelessWidget {
  const LibraryTag(
    this.name, {
    super.key,
    this.onPressed,
    this.selected = false,
  });
  final String name;
  final VoidCallback? onPressed;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return DesktopButton(
      onPressed: onPressed,
      selected: selected,
      minimumSize: const Size(0, 26),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      fontSize: 12,
      child: Text(
        name,
        style: libraryText(
          context,
          12,
          color: selected ? c.accent : c.muted,
          height: 1.5,
        ),
      ),
    );
  }
}

class LibraryMessage extends StatelessWidget {
  const LibraryMessage(this.title, {super.key, this.description, this.action});
  final String title;
  final String? description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(
      MediaQuery.textScalerOf(context).scale(1) >= 1.6 ? 16 : 24,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: libraryText(context, 17, weight: FontWeight.w600)),
        if (description != null) ...[
          const SizedBox(height: 8),
          Text(
            description!,
            textAlign: TextAlign.center,
            style: libraryText(context, 13, color: UiPalette.of(context).muted),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 14), action!],
      ],
    ),
  );
}

const _virtualDirectories = {'all', 'unfiled'};

/// One tree order and one path label for browsing and all assignment forms.
List<WorkspaceDirectory> libraryDirectoryTree(WorkspaceCatalog catalog) {
  final ordered = <WorkspaceDirectory>[];
  final visited = <String>{};
  void append(String? parent) {
    for (final d in catalog.directories.where(
      (d) => !_virtualDirectories.contains(d.id) && d.parentId == parent,
    )) {
      if (!visited.add(d.id)) continue;
      ordered.add(d);
      append(d.id);
    }
  }

  ordered.addAll(catalog.directories.where((d) => d.id == 'all'));
  append(null);
  ordered.addAll(catalog.directories.where((d) => d.id == 'unfiled'));
  return ordered;
}

List<WorkspaceDirectory> libraryDirectoryAncestors(
  WorkspaceCatalog catalog,
  WorkspaceDirectory directory,
) {
  final path = <WorkspaceDirectory>[directory];
  final visited = {directory.id};
  var parent = directory.parentId;
  while (parent != null && visited.add(parent)) {
    final d = catalog.directories.where((d) => d.id == parent).firstOrNull;
    if (d == null) break;
    path.insert(0, d);
    parent = d.parentId;
  }
  return path;
}

class LibraryDirectorySelect extends StatelessWidget {
  const LibraryDirectorySelect({
    super.key,
    required this.catalog,
    required this.value,
    required this.onChanged,
    this.parentFor,
    this.parentMode = false,
    this.errorText,
  });
  final WorkspaceCatalog catalog;
  final String? value, parentFor, errorText;
  final bool parentMode;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DesktopSelect<String?>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: parentMode ? '上级目录' : '资料目录'),
        items: [
          DropdownMenuItem(
            value: null,
            child: Text(parentMode ? '顶层目录' : '未分类'),
          ),
          for (final d in libraryDirectoryTree(catalog))
            if (!_virtualDirectories.contains(d.id) &&
                (parentFor == null ||
                    !libraryDirectoryAncestors(
                      catalog,
                      d,
                    ).any((p) => p.id == parentFor)))
              DropdownMenuItem(
                value: d.id,
                child: Text(
                  libraryDirectoryAncestors(
                    catalog,
                    d,
                  ).map((p) => p.name).join(' › '),
                ),
              ),
        ],
        onChanged: onChanged,
      ),
      if (errorText != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            errorText!,
            style: TextStyle(color: UiPalette.of(context).danger),
          ),
        ),
    ],
  );
}
