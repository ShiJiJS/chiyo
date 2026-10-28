import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import '../desktop_controls.dart';
import '../desktop_scroll.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';

/// View-only state can be shared with tools in the existing detail header.
/// An external owner resets it when the selected record/body changes; the
/// renderer otherwise creates and disposes its own controller.
class DocumentReadingController extends ValueNotifier<bool> {
  DocumentReadingController() : super(false);
  void toggle() => value = !value;
}

class LibraryDocumentTools extends StatelessWidget {
  const LibraryDocumentTools({
    super.key,
    required this.controller,
    required this.format,
    required this.canToggle,
  });
  final DocumentReadingController controller;
  final String format;
  final bool canToggle;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: controller,
    builder: (context, raw, _) => Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          format == 'markdown' ? 'Markdown' : '纯文本',
          style: libraryText(context, 12, color: UiPalette.of(context).muted),
        ),
        if (format == 'markdown' && canToggle)
          DesktopButton(
            kind: DesktopButtonKind.quiet,
            fontSize: 13,
            key: const ValueKey('library-document-raw'),
            onPressed: controller.toggle,
            child: Text(raw ? '阅读排版' : '显示原文'),
          ),
      ],
    ),
  );
}

bool libraryDocumentIsLarge(String body) =>
    body.length > 200000 || '\n'.allMatches(body).length > 4000;

/// Renders a Markdown AST to a closed set of Flutter text/layout widgets.
/// There is no HTML host, URL launcher, resource resolver or network image.
class LibraryDocument extends StatefulWidget {
  const LibraryDocument({
    super.key,
    required this.body,
    this.format = 'plain',
    this.controller,
    this.showControls = true,
    this.leadingGap = 0,
  });
  final DocumentReadingController? controller;
  final bool showControls;
  final double leadingGap;
  final String body, format;
  @override
  State<LibraryDocument> createState() => _LibraryDocumentState();
}

class _LibraryDocumentState extends State<LibraryDocument> {
  late List<md.Node> _nodes;
  final _local = DocumentReadingController();
  DocumentReadingController get _reading => widget.controller ?? _local;
  bool get _large => libraryDocumentIsLarge(widget.body);
  @override
  void dispose() {
    _local.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(LibraryDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body || oldWidget.format != widget.format) {
      _local.value = false;
      _parse();
    }
  }

  void _parse() {
    _nodes = widget.format == 'markdown' && !_large
        ? md.Document(
            encodeHtml: false,
            extensionSet: md.ExtensionSet.gitHubWeb,
          ).parse(widget.body)
        : const [];
  }

  InlineSpan _inline(md.Node node) {
    final c = UiPalette.of(context);
    if (node is md.Text) return TextSpan(text: node.text);
    if (node is! md.Element) return TextSpan(text: node.textContent);
    if (node.tag == 'img') {
      return TextSpan(
        text: '[图片：${node.attributes['alt'] ?? '未提供说明'}]',
        style: TextStyle(color: c.muted),
      );
    }
    if (node.tag == 'br') return const TextSpan(text: '\n');
    if (node.tag == 'input') {
      return TextSpan(
        text: node.attributes.containsKey('checked') ? '☑ ' : '☐ ',
      );
    }
    final children = [
      for (final child in node.children ?? <md.Node>[]) _inline(child),
    ];
    if (node.tag == 'a') {
      // Links remain readable/copyable without exposing an execution action.
      final href = node.attributes['href'] ?? '';
      final uri = Uri.tryParse(href);
      final safe =
          uri != null &&
          ['https', 'http', 'mailto'].contains(uri.scheme) &&
          !href.contains(RegExp(r'[\x00-\x1f]'));
      return TextSpan(
        children: [
          ...children,
          if (safe && href != node.textContent)
            TextSpan(
              text: '（$href）',
              style: TextStyle(color: c.muted),
            ),
        ],
      );
    }
    return TextSpan(
      children: children,
      style: switch (node.tag) {
        'strong' => const TextStyle(fontWeight: FontWeight.w700),
        'em' => const TextStyle(fontStyle: FontStyle.italic),
        'del' => const TextStyle(decoration: TextDecoration.lineThrough),
        'code' => TextStyle(
          fontFamily: 'Menlo',
          fontSize: 13,
          backgroundColor: c.rail,
        ),
        _ => null,
      },
    );
  }

  Widget _text(
    List<md.Node> nodes, {
    double size = 15,
    FontWeight? weight,
    double height = 1.95,
    Color? color,
  }) => SelectableText.rich(
    TextSpan(children: nodes.map(_inline).toList()),
    style: libraryText(
      context,
      size,
      weight: weight,
      height: height,
      color: color,
    ),
  );
  Widget _block(md.Node node, [int depth = 0]) {
    if (node is! md.Element || depth > 32) {
      return SelectableText(
        node.textContent,
        style: libraryText(context, 14, height: 1.95),
      );
    }
    final c = UiPalette.of(context), children = node.children ?? <md.Node>[];
    if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
      return _text(
        children,
        size: node.tag == 'h1'
            ? 27
            : node.tag == 'h2'
            ? 20
            : 16,
        height: node.tag == 'h1'
            ? 1.35
            : node.tag == 'h2'
            ? 1.5
            : 1.6,
        weight: FontWeight.w700,
      );
    }
    if (node.tag == 'pre') {
      // The final newline belongs to the closing Markdown fence; source view
      // retains it. Internal/intentional blank lines remain in the code block.
      final code = node.textContent.replaceFirst(RegExp(r'\n$'), '');
      final style = libraryText(
        context,
        13,
        height: 1.85,
      ).copyWith(fontFamily: 'Menlo');
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.rail,
          borderRadius: BorderRadius.circular(8),
        ),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final painter = TextPainter(
              text: TextSpan(text: code, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final fits = painter.width <= bounds.maxWidth;
            painter.dispose();
            final text = SelectableText(
              code,
              style: style,
              strutStyle: const StrutStyle(
                fontFamily: 'Menlo',
                fontSize: 15,
                height: 1.85,
              ),
            );
            return fits
                ? text
                : ScrollConfiguration(
                    behavior: const DesktopScrollBehavior(scrollbarGutter: 9),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      primary: false,
                      child: text,
                    ),
                  );
          },
        ),
      );
    }
    if (node.tag == 'ul' || node.tag == 'ol') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, child) in children.indexed)
            Padding(
              padding: EdgeInsets.zero,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: node.tag == 'ol' ? 40 : 22,
                    child: Text(
                      node.tag == 'ol'
                          ? '${(int.tryParse(node.attributes['start'] ?? '') ?? 1) + index}.'
                          : '•',
                      style: libraryText(context, 15, height: 1.95),
                    ),
                  ),
                  Expanded(child: _block(child, depth + 1)),
                ],
              ),
            ),
        ],
      );
    }
    if (node.tag == 'li' || node.tag == 'blockquote') {
      final blocks = children.any(
        (n) =>
            n is md.Element && ['p', 'ul', 'ol', 'blockquote'].contains(n.tag),
      );
      return Container(
        padding: node.tag == 'blockquote'
            ? const EdgeInsets.only(left: 16)
            : EdgeInsets.zero,
        decoration: node.tag == 'blockquote'
            ? BoxDecoration(
                border: Border(left: BorderSide(color: c.line, width: 3)),
              )
            : null,
        child: blocks
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _spacedBlocks(
                  children,
                  depth: depth + 1,
                  collapseFirstMargin: true,
                ),
              )
            : _text(children),
      );
    }
    if (node.tag == 'table') {
      final rows = <List<md.Node>>[];
      void visit(md.Node n) {
        if (n is! md.Element) return;
        if (n.tag == 'tr') {
          rows.add(n.children ?? []);
          return;
        }
        for (final child in n.children ?? <md.Node>[]) {
          visit(child);
        }
      }

      visit(node);
      if (rows.isEmpty) return const SizedBox();
      return LayoutBuilder(
        builder: (context, bounds) {
          final columns = rows
              .map((r) => r.length)
              .reduce((a, b) => a > b ? a : b);
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final width = (columns * 150 * scale)
              .clamp(bounds.maxWidth, double.infinity)
              .toDouble();
          final table = SizedBox(
            width: width,
            child: Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                for (final row in rows)
                  TableRow(
                    children: [
                      for (var i = 0; i < columns; i++)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color:
                                i < row.length &&
                                    row[i] is md.Element &&
                                    (row[i] as md.Element).tag == 'th'
                                ? c.rail
                                : null,
                            border: Border(bottom: BorderSide(color: c.line)),
                          ),
                          child: i < row.length
                              ? _text(
                                  (row[i] as md.Element).children ?? [],
                                  size: 14,
                                  weight: (row[i] as md.Element).tag == 'th'
                                      ? FontWeight.w700
                                      : null,
                                )
                              : const SizedBox(),
                        ),
                    ],
                  ),
              ],
            ),
          );
          return width <= bounds.maxWidth
              ? table
              : ScrollConfiguration(
                  behavior: const DesktopScrollBehavior(scrollbarGutter: 9),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    primary: false,
                    child: table,
                  ),
                );
        },
      );
    }
    if (node.tag == 'hr') return Divider(color: c.line);
    return _text(
      children,
      size: node.tag == 'p' ? 14 : 15,
      color: node.tag == 'p' ? c.readingInk : null,
    );
  }

  (double, double) _margins(md.Node node) {
    if (node is! md.Element) return (0, 0);
    return switch (node.tag) {
      'h1' || 'h2' => (27, 12),
      'h3' || 'h4' || 'h5' || 'h6' => (24, 10),
      'p' => (10, 10),
      'table' => (14, 14),
      'ul' || 'ol' || 'pre' || 'blockquote' => (15, 15),
      _ => (0, 0),
    };
  }

  List<Widget> _spacedBlocks(
    List<md.Node> nodes, {
    int depth = 0,
    double leadingGap = 0,
    bool collapseFirstMargin = false,
  }) {
    final blocks = <Widget>[];
    var previous = leadingGap;
    for (final node in nodes) {
      final (top, bottom) = _margins(node);
      final firstCollapsed = blocks.isEmpty && collapseFirstMargin;
      blocks.add(
        SizedBox(
          height: firstCollapsed
              ? 0
              : previous > top
              ? previous
              : top,
        ),
      );
      blocks.add(_block(node, depth));
      previous = bottom;
    }
    return blocks;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _reading,
    builder: (context, sourceVisible, _) {
      final c = UiPalette.of(context);
      final raw = sourceVisible || widget.format != 'markdown' || _large;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showControls)
            LibraryDocumentTools(
              controller: _reading,
              format: widget.format,
              canToggle: !_large,
            ),
          if (!['plain', 'markdown'].contains(widget.format) || _large)
            Text(
              _large ? '正文较长，按原文展示。' : '正文格式未知，按原文展示。',
              style: libraryText(context, 13, color: c.muted),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: libraryChWidth(
                  context,
                  libraryText(context, 15, height: 1.95),
                  74,
                ),
              ),
              child: Column(
                key: const ValueKey('library-document-reading'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.body.isEmpty)
                    Text(
                      '尚未填写正文。',
                      style: libraryText(context, 14, color: c.muted),
                    )
                  else if (raw)
                    Padding(
                      padding: EdgeInsets.only(top: widget.leadingGap),
                      child: SelectableText(
                        widget.body,
                        key: const ValueKey('library-document-text'),
                        style: libraryText(context, 14, height: 1.95),
                      ),
                    )
                  else
                    ..._spacedBlocks(_nodes, leadingGap: widget.leadingGap),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
