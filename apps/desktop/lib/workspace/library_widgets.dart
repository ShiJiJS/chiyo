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

TextStyle libraryHeading(BuildContext context, double size) =>
    libraryText(context, size, weight: FontWeight.w600, height: 1.45).copyWith(
      letterSpacing: -.4,
      fontVariations: const [FontVariation('wght', 650)],
    );

double libraryChWidth(BuildContext context, TextStyle style, int count) {
  final zero = TextPainter(
    text: TextSpan(text: '0', style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = zero.width * count;
  zero.dispose();
  return width;
}

class RecordIcon extends StatelessWidget {
  const RecordIcon(
    this.type, {
    super.key,
    this.size = 33,
    this.radius = 10,
    this.glyphSize,
  });
  final WorkspaceType type;
  final double size;
  final double radius;
  final double? glyphSize;
  static PrototypeIconGlyph glyphFor(String icon) => switch (icon) {
    'server' => PrototypeIconGlyph.server,
    'layers' => PrototypeIconGlyph.layers,
    'user' => PrototypeIconGlyph.user,
    'book' => PrototypeIconGlyph.book,
    'key' => PrototypeIconGlyph.key,
    'plugin' => PrototypeIconGlyph.plugin,
    'globe' => PrototypeIconGlyph.globe,
    _ => PrototypeIconGlyph.file,
  };
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
    final glyph = glyphFor(type.icon);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color(background),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: PrototypeIcon(
        glyph,
        size: glyphSize ?? (size > 40 ? 23 : 18),
        color: Color(ink),
      ),
    );
  }
}

class LibraryPill extends StatelessWidget {
  const LibraryPill(this.label, {super.key, this.color, this.background});
  final String label;
  final Color? color, background;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background ?? c.nav,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: libraryText(context, 13, color: color ?? c.muted),
      ),
    );
  }
}

class LibraryTag extends StatelessWidget {
  const LibraryTag(
    this.name, {
    super.key,
    this.onPressed,
    this.selected = false,
  }) : _detail = false;
  const LibraryTag.detail(
    this.name, {
    super.key,
    this.onPressed,
    this.selected = false,
  }) : _detail = true;
  final String name;
  final VoidCallback? onPressed;
  final bool selected;
  final bool _detail;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return DesktopButton(
      onPressed: onPressed,
      selected: selected,
      selectedBorder: true,
      selectedBorderColor: c.accent,
      radius: 5,
      minimumSize: Size(0, _detail ? libraryMetaHeight(context) : 26),
      // CSS includes the one-pixel border outside the tag's 7/3px padding.
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

// The detail flex row stretches pills/tags to the small edit action's height.
double libraryMetaHeight(BuildContext context) {
  final line = TextPainter(
    text: TextSpan(
      text: '标签',
      style: libraryText(context, 13, weight: FontWeight.w500),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  // Flutter rounds the laid-out line box. Stretch peers to the actual action,
  // including its CSS border-box padding, at the current font and text scale.
  final height = line.height + 16;
  line.dispose();
  return height;
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

/// Frozen .empty presentation, shared by an empty result and selection pane.
/// Reading failures keep LibraryMessage and their independent retry semantics.
class LibraryEmpty extends StatelessWidget {
  const LibraryEmpty(
    this.title, {
    super.key,
    required this.description,
    this.action,
  });
  final String title, description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final style = libraryText(context, 14, color: UiPalette.of(context).muted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 65),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              title,
              key: const ValueKey('library-empty-title'),
              textAlign: TextAlign.center,
              style: libraryText(
                context,
                17,
                height: 1.5,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: libraryChWidth(context, style, 46),
              child: Text(
                description,
                key: const ValueKey('library-empty-description'),
                textAlign: TextAlign.center,
                style: style,
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (action != null)
            Align(alignment: Alignment.center, child: action!),
        ],
      ),
    );
  }
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
          if (parentMode &&
              value != null &&
              !catalog.directories.any((d) => d.id == value))
            DropdownMenuItem(
              value: value,
              enabled: false,
              child: const Text('原上级已移除，请重新选择'),
            ),
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

/// CSS line boxes keep fractional leading between blocks. The engine's glyphs
/// and selectable text stay at their original size; only layout leading is
/// reserved independently from its rounded paragraph height.
class LibraryReadingText extends StatelessWidget {
  const LibraryReadingText({
    super.key,
    required this.span,
    required this.style,
    this.fixedLineBox = true,
    this.lineFontSize,
    this.textAlign = TextAlign.start,
  });
  final TextSpan span;
  final TextStyle style;
  final bool fixedLineBox;
  final double? lineFontSize;
  final TextAlign textAlign;
  @override
  Widget build(BuildContext context) {
    if (!fixedLineBox) return SelectableText.rich(span, style: style);
    if (span.toPlainText().isEmpty) return const SizedBox.shrink();
    final scaler = MediaQuery.textScalerOf(context);
    final lineStyle = style.copyWith(fontSize: lineFontSize ?? style.fontSize);
    final strut = StrutStyle.fromTextStyle(lineStyle, forceStrutHeight: true);
    return LayoutBuilder(
      builder: (context, bounds) {
        final painter = TextPainter(
          text: TextSpan(style: style, children: [span]),
          strutStyle: strut,
          textDirection: Directionality.of(context),
          textAlign: textAlign,
          textScaler: scaler,
        )..layout(maxWidth: bounds.maxWidth);
        final height =
            painter.computeLineMetrics().length *
            scaler.scale(lineStyle.fontSize!) *
            lineStyle.height!;
        final factor = painter.height == 0 ? 1.0 : height / painter.height;
        final width = bounds.maxWidth.isFinite ? null : painter.width;
        painter.dispose();
        return SizedBox(
          width: width,
          child: Align(
            alignment: AlignmentDirectional.topStart,
            heightFactor: factor,
            child: SizedBox(
              width: width ?? bounds.maxWidth,
              child: SelectableText.rich(
                span,
                style: style,
                strutStyle: strut,
                textAlign: textAlign,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Ordinary and credential details navigate through the same relation row.
class LibraryRelationRow extends StatelessWidget {
  const LibraryRelationRow({
    super.key,
    required this.record,
    required this.onPressed,
    this.first = true,
  });
  final WorkspaceRecordSummary record;
  final VoidCallback? onPressed;
  final bool first;
  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('library-relation-frame-${record.ref.key}'),
    decoration: BoxDecoration(
      border: first
          ? null
          : Border(top: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: DesktopButton(
      key: ValueKey('library-relation-${record.ref.key}'),
      kind: DesktopButtonKind.link,
      radius: 0,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(vertical: 14),
      onPressed: onPressed,
      child: Row(
        children: [
          RecordIcon(
            record.type,
            key: ValueKey('library-relation-icon-${record.ref.key}'),
            size: 34,
            radius: 7,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              key: ValueKey('library-relation-text-${record.ref.key}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  record.name,
                  key: ValueKey('library-relation-name-${record.ref.key}'),
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  record.description,
                  key: ValueKey(
                    'library-relation-description-${record.ref.key}',
                  ),
                  style: libraryText(
                    context,
                    13,
                    color: UiPalette.of(context).muted,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            key: ValueKey('library-relation-chevron-${record.ref.key}'),
            width: 15,
            height: 19,
            child: Center(
              child: PrototypeIcon(
                PrototypeIconGlyph.chev,
                size: 15,
                color: UiPalette.of(context).muted,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
