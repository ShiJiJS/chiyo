import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_fonts.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'library_entries.dart';
import 'library_document.dart';
import 'library_file.dart';
import 'library_credential.dart';
import 'workspace_source.dart';
import 'host_settings.dart';

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
    this.onHistory,
    this.onRecycle,
    this.onAdopt,
    this.onApproval,
    this.filePicker,
    this.credentialPicker,
    this.onModalChanged,
    required this.onSettings,
    required this.onTag,
    required this.onExpand,
  });
  final WorkspaceDetail detail;
  final WorkspaceSource source;
  final LibraryMetrics metrics;
  final int revision;
  final ValueChanged<WorkspaceRecordRef> onOpen;
  final VoidCallback? onEdit, onHistory, onRecycle;
  final VoidCallback? onAdopt;
  final ValueChanged<String>? onApproval;
  final VoidCallback onSettings, onExpand;
  final ValueChanged<String> onTag;
  final WorkspaceFilePicker? filePicker;
  final WorkspaceCredentialPicker? credentialPicker;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<LibraryDetail> createState() => _LibraryDetailState();
}

class _LibraryDetailState extends State<LibraryDetail> {
  bool _relations = false;
  final _documentReading = DocumentReadingController();
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
    if (oldWidget.detail.record.ref != widget.detail.record.ref ||
        oldWidget.detail.values['body'] != widget.detail.values['body'] ||
        oldWidget.detail.values['bodyFormat'] !=
            widget.detail.values['bodyFormat']) {
      _documentReading.value = false;
    }
    if (oldWidget.revision != widget.revision ||
        oldWidget.detail != widget.detail) {
      _loadLinks();
    }
  }

  @override
  void dispose() {
    _documentReading.dispose();
    super.dispose();
  }

  Widget _section(
    BuildContext context,
    String title,
    Widget child, {
    String? trailing,
    double? headingGap,
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
        SizedBox(height: headingGap ?? (trailing == null ? 12 : 24)),
        child,
      ],
    ),
  );

  Widget _fields(BuildContext context, List<dynamic> keys) {
    final definition = workspaceFields(widget.detail);
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
                if (field['type'] == 'file')
                  SizedBox(
                    width: bounds.maxWidth,
                    child: LibraryFile(
                      key: ValueKey(
                        'library-file-${widget.detail.record.ref.key}-${field['key']}',
                      ),
                      detail: widget.detail,
                      fieldKey: field['key'] as String,
                      source: widget.source,
                      picker: widget.filePicker,
                      onModalChanged: widget.onModalChanged,
                    ),
                  )
                else if (field['type'] == 'entries')
                  SizedBox(
                    width: bounds.maxWidth,
                    child: LibraryEntryTimeline(
                      widget.detail.values[field['key']],
                    ),
                  )
                else
                  SizedBox(
                    width: (bounds.maxWidth - 34 * (columns - 1)) / columns,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          field['label'] as String,
                          key: ValueKey('library-field-${field['key']}-label'),
                          style: libraryText(
                            context,
                            13,
                            color: UiPalette.of(context).muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          field['type'] == 'unknown'
                              ? const JsonEncoder.withIndent(
                                  '  ',
                                ).convert(widget.detail.values[field['key']])
                              : _value(widget.detail.values[field['key']]),
                          key: ValueKey('library-field-${field['key']}-value'),
                          style:
                              [
                                    'number',
                                    'url',
                                    'date',
                                  ].contains(field['type']) ||
                                  field['key'] == 'host'
                              ? libraryText(context, 13, height: 1.8).copyWith(
                                  fontFamily: 'Menlo',
                                  fontFamilyFallback: [
                                    ...desktopFontFallback,
                                    'monospace',
                                  ],
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
        for (final (index, ref) in targets.indexed)
          if (summaries[ref] case final record?)
            Container(
              key: ValueKey('library-relation-frame-${ref.key}'),
              decoration: BoxDecoration(
                border: index == 0
                    ? null
                    : Border(
                        top: BorderSide(color: UiPalette.of(context).line),
                      ),
              ),
              child: DesktopButton(
                key: ValueKey('library-relation-${ref.key}'),
                kind: DesktopButtonKind.link,
                radius: 0,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(vertical: 14),
                onPressed: () => widget.onOpen(ref),
                child: Row(
                  children: [
                    RecordIcon(record.type, size: 34, radius: 7),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            record.name,
                            key: ValueKey('library-relation-name-${ref.key}'),
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.6,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            record.description,
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
                      key: ValueKey('library-relation-chevron-${ref.key}'),
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

  Widget _description(BuildContext context, String value) {
    final style = libraryText(
      context,
      14,
      color: UiPalette.of(context).muted,
      height: 1.8,
    );
    // The frozen paragraph has max-width:65ch. Use the same installed font
    // and scaler for the zero glyph instead of a platform-specific pixel cap.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: libraryChWidth(context, style, 65),
        child: Text(
          value,
          key: const ValueKey('library-detail-description'),
          style: style,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail,
        record = detail.record,
        c = UiPalette.of(context);
    final documentSection =
        record.type.id == 'document' &&
            detail.templateState == WorkspaceTemplateState.available
        ? (detail.definition['sections'] as List? ?? [])
              .whereType<Map>()
              .where(
                (s) =>
                    s['kind'] == 'text' &&
                    s['key'] == 'body' &&
                    s['formatKey'] == 'bodyFormat',
              )
              .firstOrNull
        : null;
    final declaredFields = (detail.definition['fields'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final declaredSections = (detail.definition['sections'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final primaryFile =
        detail.templateState == WorkspaceTemplateState.available &&
        workspaceFileTypeIds.contains(record.type.id) &&
        detail.definition['id'] == record.type.id &&
        declaredFields.length == 1 &&
        declaredFields.single['key'] == 'file' &&
        declaredFields.single['type'] == 'file' &&
        declaredSections.any((s) => s['kind'] == 'fields') &&
        declaredSections.every(
          (s) =>
              s['kind'] == 'relations' ||
              (s['kind'] == 'fields' &&
                  (s['keys'] as List?)?.length == 1 &&
                  (s['keys'] as List).single == 'file'),
        );
    final primaryCredential =
        record.ref.kind == WorkspaceRecordKind.credential &&
        detail.templateState == WorkspaceTemplateState.available &&
        declaredFields.isEmpty &&
        declaredSections.isEmpty;
    final standalone =
        documentSection != null || primaryFile || primaryCredential;
    final tabs = <Widget>[
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
    ];
    final editButton = DesktopButton(
      kind: DesktopButtonKind.quiet,
      onPressed: widget.onEdit,
      fontSize: 13,
      padding: EdgeInsets.symmetric(vertical: standalone ? 8 : 10),
      child: const Text('编辑信息'),
    );
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
                      style:
                          libraryText(
                            context,
                            widget.metrics.titleSize,
                            height: 1.45,
                            weight: FontWeight.w600,
                          ).copyWith(
                            letterSpacing: -.4,
                            fontVariations: [
                              const FontVariation('wght', 650),
                              // Match CSS automatic optical sizing for the same
                              // installed variable face and actual logical size.
                              FontVariation.opticalSize(
                                MediaQuery.textScalerOf(
                                  context,
                                ).scale(widget.metrics.titleSize),
                              ),
                            ],
                          ),
                    ),
                    const SizedBox(height: 6),
                    _description(context, record.description),
                    const SizedBox(height: 11),
                    Wrap(
                      key: const ValueKey('library-detail-meta'),
                      spacing: 7,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          key: const ValueKey('library-detail-type'),
                          height: libraryMetaHeight(context),
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          decoration: BoxDecoration(
                            color: c.nav,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              record.type.name,
                              style: libraryText(context, 13, color: c.muted),
                            ),
                          ),
                        ),
                        for (final tag in record.tags)
                          LibraryTag.detail(
                            tag.name,
                            key: ValueKey('library-detail-tag-${tag.id}'),
                            onPressed: () => widget.onTag(tag.id),
                          ),
                        DesktopButton(
                          key: const ValueKey('library-detail-edit-tags'),
                          kind: DesktopButtonKind.quiet,
                          onPressed: widget.onEdit,
                          leading: const PrototypeIcon(
                            PrototypeIconGlyph.plus,
                            size: 19,
                          ),
                          fontSize: 13,
                          minimumSize: Size(0, libraryMetaHeight(context)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 8,
                          ),
                          child: const Text('标签'),
                        ),
                        if (documentSection != null) ...[
                          LibraryDocumentTools(
                            controller: _documentReading,
                            format: detail.values['bodyFormat'] is String
                                ? detail.values['bodyFormat'] as String
                                : 'unknown',
                            canToggle: !libraryDocumentIsLarge(
                              detail.values['body']?.toString() ?? '',
                            ),
                          ),
                        ],
                        if (standalone) editButton,
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: widget.metrics.headerGap),
              DesktopButton(
                key: const ValueKey('library-detail-expand'),
                onPressed: widget.onExpand,
                tooltip: '展开阅读',
                kind: DesktopButtonKind.quiet,
                minimumSize: const Size(36, 36),
                padding: const EdgeInsets.all(8),
                child: const PrototypeIcon(PrototypeIconGlyph.expand, size: 19),
              ),
              const SizedBox(width: 2),
              SizedBox(
                width: 36,
                child: DesktopSelect<String>(
                  compact: true,
                  quiet: true,
                  minimumTriggerSize: const Size(36, 36),
                  triggerPadding: const EdgeInsets.all(8),
                  tooltip: '资料操作',
                  triggerLabel: const PrototypeIcon(
                    PrototypeIconGlyph.more,
                    size: 19,
                  ),
                  key: const ValueKey('library-record-actions'),
                  items: [
                    const DropdownMenuItem(value: 'edit', child: Text('编辑信息')),
                    if (widget.onAdopt != null)
                      const DropdownMenuItem(
                        value: 'adopt',
                        child: Text('采用资料模板'),
                      ),
                    if (widget.onHistory != null)
                      DropdownMenuItem(
                        value: 'history',
                        child: Text(
                          record.ref.kind == WorkspaceRecordKind.credential
                              ? '材料版本'
                              : '内容版本',
                        ),
                      ),
                    if (widget.onRecycle != null)
                      const DropdownMenuItem(
                        value: 'recycle',
                        child: Text('移到回收站'),
                      ),
                  ],
                  onChanged: widget.onEdit == null
                      ? null
                      : (action) {
                          switch (action) {
                            case 'adopt':
                              widget.onAdopt?.call();
                            case 'history':
                              widget.onHistory?.call();
                            case 'recycle':
                              widget.onRecycle?.call();
                            default:
                              widget.onEdit?.call();
                          }
                        },
                ),
              ),
            ],
          ),
          if (!standalone) ...[
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Row(children: [...tabs, const Spacer(), editButton]),
            ),
          ],
          if (detail.templateState != WorkspaceTemplateState.available)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(
                detail.templateState == WorkspaceTemplateState.disabled
                    ? '模板插件已停用，按保留的字段显示。已有内容可继续编辑。'
                    : detail.templateState ==
                          WorkspaceTemplateState.removedDefinition
                    ? '当前插件不再提供此模板，按保留的字段显示。已有内容可继续编辑。'
                    : '模板插件未安装，按保留的字段显示。已有内容可继续编辑。',
                key: const ValueKey('library-template-unavailable'),
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          if (detail.definition['legacyTemplateVersion'] case final int version)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(
                '沿用旧版模板第$version版的录入结构；字段内容由这份资料独立保存。',
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          FutureBuilder<List<WorkspaceRecordSummary>>(
            future: _links,
            builder: (context, snapshot) {
              final sections =
                  detail.templateState == WorkspaceTemplateState.available
                  ? detail.definition['sections'] as List? ?? []
                  : const [];
              if (_relations && !standalone) {
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
              if (primaryFile) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 27),
                      child: LibraryFile(
                        key: ValueKey('library-file-${record.ref.key}-file'),
                        detail: detail,
                        fieldKey: 'file',
                        source: widget.source,
                        picker: widget.filePicker,
                        onModalChanged: widget.onModalChanged,
                      ),
                    ),
                    for (final section in declaredSections.where(
                      (s) => s['kind'] == 'relations',
                    ))
                      _section(
                        context,
                        section['title'] as String,
                        _relationsFor(
                          context,
                          section['key'] as String,
                          snapshot,
                        ),
                      ),
                  ],
                );
              }
              if (sections.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (record.ref.kind == WorkspaceRecordKind.credential)
                      LibraryCredential(
                        key: ValueKey(record.ref),
                        ref: record.ref,
                        source: widget.source,
                        revision: widget.revision,
                        onOpen: widget.onOpen,
                        onModalChanged: widget.onModalChanged,
                        picker: widget.credentialPicker,
                        onApproval: widget.onApproval,
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
                    if (detail.templateState !=
                        WorkspaceTemplateState.available)
                      for (final entry in detail.values.entries)
                        if (!(detail.definition['fields'] as List? ?? []).any(
                              (f) => f['key'] == entry.key,
                            ) &&
                            !detail.retainedFields.any(
                              (f) => f['key'] == entry.key,
                            ) &&
                            !((detail.definition['fields'] as List? ?? [])
                                    .isEmpty &&
                                entry.key == 'body'))
                          _section(
                            context,
                            entry.key,
                            SelectableText(
                              entry.value is String
                                  ? entry.value as String
                                  : const JsonEncoder.withIndent(
                                      '  ',
                                    ).convert(entry.value),
                              style: libraryText(context, 14, height: 1.7),
                            ),
                          ),
                    for (final relation in detail.relations.entries)
                      if (record.ref.kind != WorkspaceRecordKind.credential)
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
                                  child: HostIdentityButton(
                                    source: widget.source,
                                    record: record.ref,
                                    onPressed: widget.onSettings,
                                  ),
                                ),
                              ),
                            _fields(context, section['keys'] as List),
                          ],
                        ),
                        // Adjacent heading/grid CSS margins collapse to 13px.
                        // A host-identity action separates them on servers.
                        headingGap:
                            record.type.id == 'server' &&
                                (section['keys'] as List).contains('host')
                            ? 12
                            : 0,
                      )
                    else if (section['kind'] == 'relations')
                      _section(
                        context,
                        detail.retainedRelations.any(
                              (r) => r['key'] == section['key'],
                            )
                            ? _relationName(section['key'] as String)
                            : section['title'] as String,
                        _relationsFor(
                          context,
                          section['key'] as String,
                          snapshot,
                        ),
                        trailing:
                            '${detail.relations[section['key']]?.length ?? 0} 项',
                      )
                    else if (section['kind'] == 'timeline')
                      _section(
                        context,
                        section['title'] as String,
                        LibraryEntryTimeline(
                          detail.values[section['key']],
                          key: ValueKey('library-timeline-${section['key']}'),
                        ),
                        headingGap: 0,
                      )
                    else if (identical(section, documentSection))
                      LibraryDocument(
                        key: ValueKey('library-document-${section['key']}'),
                        body: detail.values['body'] is String
                            ? detail.values['body'] as String
                            : _value(detail.values['body']),
                        format: detail.values['bodyFormat'] is String
                            ? detail.values['bodyFormat'] as String
                            : 'unknown',
                        controller: _documentReading,
                        showControls: false,
                        leadingGap: 22,
                      )
                    else if (section['kind'] == 'text')
                      _section(
                        context,
                        section['title'] as String,
                        LibraryDocument(
                          key: ValueKey('library-document-${section['key']}'),
                          showControls: section['formatKey'] is String,
                          body: detail.values[section['key']] is String
                              ? detail.values[section['key']] as String
                              : _value(detail.values[section['key']]),
                          format: section['formatKey'] is String
                              ? (detail.values[section['formatKey']] is String
                                    ? detail.values[section['formatKey']]
                                          as String
                                    : 'unknown')
                              : 'plain',
                        ),
                      )
                    else
                      _section(
                        context,
                        section['title'] as String,
                        SelectableText(_value(detail.values[section['key']])),
                      ),
                  for (final relation in detail.relations.entries)
                    if (relation.value.isNotEmpty &&
                        !sections.any(
                          (s) =>
                              s['kind'] == 'relations' &&
                              s['key'] == relation.key,
                        ))
                      _section(
                        context,
                        _relationName(relation.key),
                        _relationsFor(context, relation.key, snapshot),
                        trailing: '${relation.value.length} 项',
                      ),
                ],
              );
            },
          ),
          if ((!_relations || standalone) &&
              detail.fieldOverrides.entries.any(
                (e) =>
                    e.value != null &&
                    !(detail.definition['fields'] as List? ?? []).any(
                      (f) => f['key'] == e.key,
                    ) &&
                    !detail.retainedFields.any((f) => f['key'] == e.key),
              ))
            _section(
              context,
              '补充字段',
              _fields(
                context,
                detail.fieldOverrides.entries
                    .where(
                      (e) =>
                          e.value != null &&
                          !(detail.definition['fields'] as List? ?? []).any(
                            (f) => f['key'] == e.key,
                          ) &&
                          !detail.retainedFields.any((f) => f['key'] == e.key),
                    )
                    .map((e) => e.key)
                    .toList(),
              ),
            ),
          if ((!_relations || standalone) && detail.retainedFields.isNotEmpty)
            _section(
              context,
              '保留的原字段',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '这些内容没有被目标模板覆盖。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  _fields(
                    context,
                    detail.retainedFields.map((f) => f['key']).toList(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _relationName(String key) {
    for (final relation
        in workspaceEditingDefinition(widget.detail)['relations'] as List? ??
            []) {
      if (relation['key'] == key) return relation['label'] as String;
    }
    return key == 'credentials' ? '关联凭据' : '关联资料';
  }
}
