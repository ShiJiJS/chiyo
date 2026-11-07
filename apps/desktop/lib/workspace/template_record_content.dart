import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_fonts.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'library_entries.dart';
import 'library_document.dart';
import 'workspace_source.dart';

/// The shared plugin display for library records and proposal previews.
/// Hosts supply file/credential views and link actions for their own context.
/// This widget never writes records or chooses a navigation destination.
class TemplateRecordContent extends StatefulWidget {
  const TemplateRecordContent({
    super.key,
    required this.detail,
    required this.relations,
    required this.onOpen,
    required this.fileBuilder,
    required this.credentialBuilder,
    required this.documentController,
    this.hostIdentity,
    this.changedKeys = const {},
    this.relationsOnly = false,
    this.credentialIncludesRelations = true,
  });
  final WorkspaceDetail detail;
  final Set<String> changedKeys;
  final WorkspaceRelationSource relations;
  final ValueChanged<WorkspaceRecordRef>? onOpen;
  final Widget Function(String fieldKey) fileBuilder;
  final WidgetBuilder credentialBuilder;
  final DocumentReadingController documentController;
  final Widget? hostIdentity;
  final bool relationsOnly;
  final bool credentialIncludesRelations;
  @override
  State<TemplateRecordContent> createState() => _TemplateRecordContentState();
}

class _TemplateRecordContentState extends State<TemplateRecordContent> {
  late Future<List<WorkspaceRecordSummary>> _links;
  void _loadLinks() {
    _links = widget.relations.readSummaries(
      widget.detail.visibleRelations.values.expand((r) => r),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  @override
  void didUpdateWidget(covariant TemplateRecordContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail != widget.detail ||
        oldWidget.relations != widget.relations) {
      _loadLinks();
    }
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
                    child: widget.fileBuilder(field['key'] as String),
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
                          '${field['label']}${widget.changedKeys.contains(field['key']) ? ' · 已修改' : ''}',
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
    final targets = widget.detail.visibleRelations[key] ?? [];
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
            LibraryRelationRow(
              record: record,
              first: index == 0,
              onPressed: widget.onOpen == null
                  ? null
                  : () => widget.onOpen!(ref),
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
        if (widget.detail.incomingRelations[key]?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '来自对方资料的关联，可打开对应资料修改。',
              style: libraryText(
                context,
                12,
                color: UiPalette.of(context).muted,
              ),
            ),
          ),
      ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<List<WorkspaceRecordSummary>>(
          future: _links,
          builder: (context, snapshot) {
            final sections =
                detail.templateState == WorkspaceTemplateState.available
                ? detail.definition['sections'] as List? ?? []
                : const [];
            if (widget.relationsOnly && !standalone) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final relation in detail.visibleRelations.entries)
                    _section(
                      context,
                      _relationName(relation.key),
                      _relationsFor(context, relation.key, snapshot),
                    ),
                  if (detail.visibleRelations.isEmpty)
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
                    padding: const EdgeInsets.only(top: 18),
                    child: widget.fileBuilder('file'),
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
                    widget.credentialBuilder(context)
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
                  if (detail.templateState != WorkspaceTemplateState.available)
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
                  for (final relation in detail.visibleRelations.entries)
                    if (record.ref.kind != WorkspaceRecordKind.credential ||
                        !widget.credentialIncludesRelations)
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
                          if (widget.hostIdentity != null &&
                              record.type.id == 'server' &&
                              (section['keys'] as List).contains('host'))
                            Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: widget.hostIdentity!,
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
                          '${detail.visibleRelations[section['key']]?.length ?? 0} 项',
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
                      controller: widget.documentController,
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
                for (final relation in detail.visibleRelations.entries)
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
        if ((!widget.relationsOnly || standalone) &&
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
        if ((!widget.relationsOnly || standalone) &&
            detail.retainedFields.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 27),
            child: _fields(
              context,
              detail.retainedFields.map((f) => f['key']).toList(),
            ),
          ),
      ],
    );
  }
}
