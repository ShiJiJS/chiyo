import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

/// Reads a template snapshot for display; it does not own persistence or infer
/// authorization from a link. Related identities resolve as metadata only.
class LibraryDetail extends StatefulWidget {
  const LibraryDetail({
    super.key,
    required this.detail,
    required this.source,
    required this.metrics,
    required this.revision,
    required this.onOpen,
    required this.onEdit,
    required this.onSettings,
    required this.onTag,
    required this.onExpand,
  });
  final WorkspaceDetail detail;
  final WorkspaceSource source;
  final LibraryMetrics metrics;
  final int revision;
  final ValueChanged<WorkspaceRecordRef> onOpen;
  final VoidCallback? onEdit;
  final VoidCallback onSettings, onExpand;
  final ValueChanged<String> onTag;
  @override
  State<LibraryDetail> createState() => _LibraryDetailState();
}

class _LibraryDetailState extends State<LibraryDetail> {
  bool _relations = false;
  late Future<List<WorkspaceRecordSummary>> _links;
  void _loadLinks() {
    _links = widget.source.readSummaries(
      widget.detail.relations.values.expand((r) => r),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  @override
  void didUpdateWidget(covariant LibraryDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        oldWidget.detail != widget.detail) {
      _loadLinks();
    }
  }

  Widget _section(
    BuildContext context,
    String title,
    Widget child, {
    String? trailing,
  }) => Padding(
    padding: const EdgeInsets.only(top: 27),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: libraryText(
                  context,
                  17,
                  height: 1.5,
                  weight: FontWeight.w700,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: libraryText(
                  context,
                  12,
                  color: UiPalette.of(context).muted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );

  Widget _fields(BuildContext context, List<dynamic> keys) {
    final definition = widget.detail.definition['fields'] as List? ?? [];
    final fields = [
      for (final key in keys) ...definition.where((f) => f['key'] == key),
    ];
    return LayoutBuilder(
      builder: (context, bounds) {
        final columns =
            bounds.maxWidth >= 480 &&
                MediaQuery.textScalerOf(context).scale(1) < 1.6
            ? 2
            : 1;
        return Padding(
          padding: const EdgeInsets.only(top: 13),
          child: Wrap(
            spacing: 34,
            runSpacing: 22,
            children: [
              for (final field in fields)
                SizedBox(
                  width: (bounds.maxWidth - 34 * (columns - 1)) / columns,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        field['label'] as String,
                        style: libraryText(
                          context,
                          13,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        _value(widget.detail.values[field['key']]),
                        style:
                            ['number', 'url', 'date'].contains(field['type']) ||
                                field['key'] == 'host'
                            ? libraryText(context, 13, height: 1.8).copyWith(
                                fontFamily: 'Menlo',
                                fontFamilyFallback: const ['monospace'],
                              )
                            : libraryText(context, 14, height: 1.8),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _value(Object? value) {
    if (value == null || value == '') return '未填写';
    if (value is List) return value.map(_value).join('\n');
    if (value is Map) return value.values.map(_value).join(' · ');
    return value.toString();
  }

  Widget _relationsFor(
    BuildContext context,
    String key,
    AsyncSnapshot<List<WorkspaceRecordSummary>> snapshot,
  ) {
    final targets = widget.detail.relations[key] ?? [];
    final summaries = {
      for (final r in snapshot.data ?? <WorkspaceRecordSummary>[]) r.ref: r,
    };
    if (targets.isEmpty) {
      return Text(
        '尚未关联。',
        style: libraryText(context, 13, color: UiPalette.of(context).muted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final ref in targets)
          if (summaries[ref] case final record?)
            DesktopButton(
              key: ValueKey('library-relation-${ref.key}'),
              kind: DesktopButtonKind.quiet,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(vertical: 14),
              onPressed: () => widget.onOpen(ref),
              child: Row(
                children: [
                  RecordIcon(record.type, size: 34),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          record.name,
                          style: libraryText(
                            context,
                            14,
                            weight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          record.description,
                          style: libraryText(
                            context,
                            13,
                            color: UiPalette.of(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  const PrototypeIcon(PrototypeIconGlyph.chev, size: 14),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                snapshot.connectionState == ConnectionState.waiting
                    ? '正在读取关联资料…'
                    : snapshot.hasError
                    ? '关联资料暂时无法读取，请刷新重试。'
                    : '关联目标已不可用。',
                style: libraryText(
                  context,
                  13,
                  color: UiPalette.of(context).muted,
                ),
              ),
            ),
      ],
    );
  }

  Widget _tab(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onPressed,
  ) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: selected ? UiPalette.of(context).accent : Colors.transparent,
          width: 2,
        ),
      ),
    ),
    child: DesktopButton(
      kind: DesktopButtonKind.quiet,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(vertical: 10),
      minimumSize: const Size(0, 44.4),
      child: Text(
        label,
        style: libraryText(
          context,
          14,
          weight: FontWeight.w500,
          color: selected
              ? UiPalette.of(context).accent
              : UiPalette.of(context).muted,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail,
        record = detail.record,
        c = UiPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RecordIcon(record.type, size: widget.metrics.iconSize),
              SizedBox(width: widget.metrics.headerGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      record.name,
                      key: const ValueKey('library-detail-title'),
                      style: libraryText(
                        context,
                        widget.metrics.titleSize,
                        height: 1.45,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      record.description,
                      style: libraryText(context, 14, color: c.muted),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: c.nav,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            record.type.name,
                            style: libraryText(context, 12, color: c.muted),
                          ),
                        ),
                        for (final tag in record.tags)
                          LibraryTag(
                            tag.name,
                            onPressed: () => widget.onTag(tag.id),
                          ),
                        DesktopButton(
                          kind: DesktopButtonKind.quiet,
                          onPressed: widget.onEdit,
                          leading: const PrototypeIcon(
                            PrototypeIconGlyph.plus,
                            size: 16,
                          ),
                          fontSize: 13,
                          child: const Text('标签'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              DesktopButton(
                onPressed: widget.onExpand,
                tooltip: '展开阅读',
                kind: DesktopButtonKind.quiet,
                minimumSize: const Size(37, 36),
                padding: const EdgeInsets.all(8),
                child: const PrototypeIcon(PrototypeIconGlyph.expand),
              ),
              const SizedBox(width: 2),
              SizedBox(
                width: 37,
                child: DesktopSelect<String>(
                  compact: true,
                  quiet: true,
                  triggerLabel: const PrototypeIcon(PrototypeIconGlyph.more),
                  items: const [
                    DropdownMenuItem(value: 'edit', child: Text('编辑信息')),
                  ],
                  onChanged: widget.onEdit == null
                      ? null
                      : (_) => widget.onEdit?.call(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                _tab(
                  context,
                  '概览',
                  !_relations,
                  () => setState(() => _relations = false),
                ),
                const SizedBox(width: 24),
                _tab(
                  context,
                  '关联资料',
                  _relations,
                  () => setState(() => _relations = true),
                ),
                const Spacer(),
                DesktopButton(
                  kind: DesktopButtonKind.quiet,
                  onPressed: widget.onEdit,
                  fontSize: 13,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: const Text('编辑信息'),
                ),
              ],
            ),
          ),
          FutureBuilder<List<WorkspaceRecordSummary>>(
            future: _links,
            builder: (context, snapshot) {
              final sections = detail.definition['sections'] as List? ?? [];
              if (_relations) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final relation in detail.relations.entries)
                      _section(
                        context,
                        _relationName(relation.key),
                        _relationsFor(context, relation.key, snapshot),
                      ),
                    if (detail.relations.isEmpty)
                      Text(
                        '还没有关联资料。',
                        style: libraryText(context, 13, color: c.muted),
                      ),
                  ],
                );
              }
              if (sections.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (record.ref.kind == WorkspaceRecordKind.credential)
                      Text(
                        '凭据内容通过专用使用流程管理。',
                        style: libraryText(context, 14, color: c.muted),
                      )
                    else if ((detail.definition['fields'] as List? ?? [])
                        .isNotEmpty)
                      _fields(context, [
                        for (final f in detail.definition['fields'] as List)
                          f['key'],
                      ])
                    else
                      SelectableText(
                        _value(detail.values['body'] ?? record.description),
                      ),
                    for (final relation in detail.relations.entries)
                      _section(
                        context,
                        _relationName(relation.key),
                        _relationsFor(context, relation.key, snapshot),
                      ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final section in sections)
                    if (section['kind'] == 'fields')
                      _section(
                        context,
                        section['title'] as String,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (record.type.id == 'server' &&
                                (section['keys'] as List).contains('host'))
                              Padding(
                                padding: const EdgeInsets.only(top: 7),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: DesktopButton(
                                    kind: DesktopButtonKind.quiet,
                                    onPressed: widget.onSettings,
                                    fontSize: 13,
                                    leading: const PrototypeIcon(
                                      PrototypeIconGlyph.shield,
                                      size: 16,
                                    ),
                                    child: const Text('主机身份'),
                                  ),
                                ),
                              ),
                            _fields(context, section['keys'] as List),
                          ],
                        ),
                      )
                    else if (section['kind'] == 'relations')
                      _section(
                        context,
                        section['title'] as String,
                        _relationsFor(
                          context,
                          section['key'] as String,
                          snapshot,
                        ),
                        trailing:
                            '${detail.relations[section['key']]?.length ?? 0} 项',
                      )
                    else
                      _section(
                        context,
                        section['title'] as String,
                        SelectableText(_value(detail.values[section['key']])),
                      ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _relationName(String key) {
    for (final relation
        in widget.detail.definition['relations'] as List? ?? []) {
      if (relation['key'] == key) return relation['label'] as String;
    }
    return '关联资料';
  }
}
