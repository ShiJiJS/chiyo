import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';

/// Renders a Markdown AST to a closed set of Flutter text/layout widgets.
/// There is no HTML host, URL launcher, resource resolver or network image.
class LibraryDocument extends StatefulWidget {
  const LibraryDocument({super.key, required this.body, this.format = 'plain'});
  final String body, format;
  @override
  State<LibraryDocument> createState() => _LibraryDocumentState();
}

class _LibraryDocumentState extends State<LibraryDocument> {
  late List<md.Node> _nodes;
  bool _raw = false;
  bool get _large =>
      widget.body.length > 200000 || '\n'.allMatches(widget.body).length > 4000;
  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(LibraryDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body || oldWidget.format != widget.format) {
      _raw = false;
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
        'strong' => const TextStyle(fontWeight: FontWeight.w600),
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

  Widget _text(List<md.Node> nodes, {double size = 14, FontWeight? weight}) =>
      SelectableText.rich(
        TextSpan(children: nodes.map(_inline).toList()),
        style: libraryText(context, size, weight: weight, height: 1.95),
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
      return Padding(
        padding: const EdgeInsets.only(top: 27, bottom: 12),
        child: _text(
          children,
          size: node.tag == 'h1'
              ? 24
              : node.tag == 'h2'
              ? 20
              : 16,
          weight: FontWeight.w600,
        ),
      );
    }
    if (node.tag == 'pre') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.rail,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          child: SelectableText(
            node.textContent,
            style: libraryText(
              context,
              13,
              height: 1.85,
            ).copyWith(fontFamily: 'Menlo'),
          ),
        ),
      );
    }
    if (node.tag == 'ul' || node.tag == 'ol') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, child) in children.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      node.tag == 'ol'
                          ? '${(int.tryParse(node.attributes['start'] ?? '') ?? 1) + index}.'
                          : '•',
                      style: libraryText(context, 14, height: 1.95),
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
                children: [for (final n in children) _block(n, depth + 1)],
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
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: SizedBox(
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
                                    weight: (row[i] as md.Element).tag == 'th'
                                        ? FontWeight.w600
                                        : null,
                                  )
                                : const SizedBox(),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      );
    }
    if (node.tag == 'hr') return Divider(color: c.line);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: _text(children),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final raw = _raw || widget.format != 'markdown' || _large;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              widget.format == 'markdown' ? 'Markdown' : '纯文本',
              style: libraryText(context, 12, color: c.muted),
            ),
            if (widget.format == 'markdown' && !_large)
              DesktopButton(
                kind: DesktopButtonKind.quiet,
                key: const ValueKey('library-document-raw'),
                onPressed: () => setState(() => _raw = !_raw),
                child: Text(_raw ? '阅读排版' : '显示原文'),
              ),
          ],
        ),
        if (!['plain', 'markdown'].contains(widget.format) || _large)
          Text(
            _large ? '正文较长，按原文展示。' : '正文格式未知，按原文展示。',
            style: libraryText(context, 13, color: c.muted),
          ),
        if (widget.body.isEmpty)
          Text('尚未填写正文。', style: libraryText(context, 14, color: c.muted))
        else if (raw)
          SelectableText(
            widget.body,
            key: const ValueKey('library-document-text'),
            style: libraryText(context, 14, height: 1.95),
          )
        else
          for (final node in _nodes) _block(node),
      ],
    );
  }
}
