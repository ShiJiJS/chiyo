import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_document.dart';
import 'library_entries.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

List<({String title, List<WorkspaceProposalFieldChange> changes})>
proposalChangeSections(WorkspaceProposalItem item) {
  final remaining = List<WorkspaceProposalFieldChange>.of(item.changes);
  final sections =
      <({String title, List<WorkspaceProposalFieldChange> changes})>[];
  for (final raw in item.proposed.definition['sections'] as List? ?? []) {
    if (raw is! Map) continue;
    final keys = <String>{
      if (raw['keys'] is List) ...(raw['keys'] as List).whereType<String>(),
      if (raw['key'] is String) raw['key'] as String,
      if (raw['formatKey'] is String) raw['formatKey'] as String,
    };
    final changes = remaining.where((c) => keys.contains(c.key)).toList();
    if (changes.isEmpty) continue;
    sections.add((
      title: raw['title'] is String ? raw['title'] as String : '字段变化',
      changes: List.unmodifiable(changes),
    ));
    remaining.removeWhere((c) => keys.contains(c.key));
  }
  if (remaining.isNotEmpty) {
    sections.add((title: '补充与保留字段', changes: List.unmodifiable(remaining)));
  }
  return List.unmodifiable(sections);
}

Widget proposalSection(BuildContext context, String title, Widget child) =>
    Padding(
      padding: const EdgeInsets.only(top: 25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: libraryText(context, 17, weight: FontWeight.w700)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
String proposalValue(Object? value) => value == null || value == ''
    ? '未填写'
    : value is String
    ? value
    : const JsonEncoder.withIndent('  ').convert(value);

class ProposalPill extends StatelessWidget {
  const ProposalPill(this.label, {super.key, this.color, this.background});
  final String label;
  final Color? color, background;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: background ?? UiPalette.of(context).rail,
      border: Border.all(color: UiPalette.of(context).line),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: libraryText(
        context,
        12,
        color: color ?? UiPalette.of(context).muted,
        height: 1.5,
      ),
    ),
  );
}

class ProposalDiff extends StatelessWidget {
  const ProposalDiff({
    super.key,
    required this.label,
    required this.before,
    required this.after,
    this.currentLabel = '当前内容',
    this.afterLabel = '提案内容',
    this.highlightAfter = true,
  });
  final String label, before, after, currentLabel, afterLabel;
  final bool highlightAfter;
  Widget _column(BuildContext context, String label, String value, bool next) =>
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: next && highlightAfter
              ? UiPalette.of(context).successSurface
              : UiPalette.of(context).rail,
          border: Border.all(color: UiPalette.of(context).line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).muted,
              ),
            ),
            const SizedBox(height: 15),
            SelectableText(
              value,
              style: libraryText(context, 22, height: 1.7).copyWith(
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['PingFang SC'],
              ),
            ),
          ],
        ),
      );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: libraryText(context, 14, color: UiPalette.of(context).muted),
      ),
      const SizedBox(height: 15),
      LayoutBuilder(
        builder: (context, b) =>
            b.maxWidth < 560 || MediaQuery.textScalerOf(context).scale(1) >= 1.6
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _column(context, currentLabel, before, false),
                  const SizedBox(height: 16),
                  _column(context, afterLabel, after, true),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _column(context, currentLabel, before, false),
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: _column(context, afterLabel, after, true)),
                ],
              ),
      ),
    ],
  );
}

class ProposalItemReading extends StatefulWidget {
  const ProposalItemReading({
    super.key,
    required this.item,
    required this.review,
    required this.catalog,
    required this.relations,
    required this.onRecord,
    this.enabled = true,
  });
  final WorkspaceProposalItem item;
  final WorkspaceProposalItemReview review;
  final WorkspaceCatalog catalog;
  final WorkspaceRelationSource relations;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final bool enabled;
  @override
  State<ProposalItemReading> createState() => _ProposalItemReadingState();
}

class _ProposalItemReadingState extends State<ProposalItemReading> {
  late Future<List<WorkspaceRecordSummary>> _related;
  void _load() => _related = widget.relations.readSummaries(
    widget.review.relations.values.expand((x) => x),
  );
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProposalItemReading old) {
    super.didUpdateWidget(old);
    if (old.item != widget.item || old.review != widget.review) _load();
  }

  Widget _value(Map<String, Object?> f) {
    final key = f['key'] as String, value = widget.review.values[key];
    if (f['type'] == 'entries') return LibraryEntryTimeline(value);
    if (f['type'] == 'file') {
      return Text(
        '普通附件需通过信息库导入，提案不包含文件原文。',
        style: libraryText(context, 13, color: UiPalette.of(context).muted),
      );
    }
    return SelectableText(
      proposalValue(value),
      style: libraryText(context, 15, weight: FontWeight.w600, height: 1.9),
    );
  }

  Widget _fields(List<String> keys) {
    final fields = workspaceFields(
      widget.item.proposed,
    ).where((f) => keys.contains(f['key'])).toList();
    return LayoutBuilder(
      builder: (context, b) {
        final two =
            b.maxWidth >= 600 &&
            MediaQuery.textScalerOf(context).scale(1) < 1.6;
        return Wrap(
          spacing: 30,
          runSpacing: 22,
          children: [
            for (final f in fields)
              SizedBox(
                width: two ? (b.maxWidth - 30) / 2 : b.maxWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      f['label'] as String? ?? f['key'] as String,
                      style: libraryText(
                        context,
                        13,
                        color: UiPalette.of(context).muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _value(f),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _links(String key) => FutureBuilder<List<WorkspaceRecordSummary>>(
    future: _related,
    builder: (context, state) {
      final refs = widget.review.relations[key] ?? [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (refs.isEmpty)
            Text(
              '未关联',
              style: libraryText(
                context,
                14,
                color: UiPalette.of(context).muted,
              ),
            ),
          for (final ref in refs)
            Builder(
              builder: (context) {
                final record = state.data
                    ?.where((r) => r.ref == ref)
                    .firstOrNull;
                return DesktopButton(
                  kind: DesktopButtonKind.quiet,
                  alignment: Alignment.centerLeft,
                  onPressed:
                      widget.enabled &&
                          state.connectionState == ConnectionState.done &&
                          !state.hasError &&
                          record != null
                      ? () => widget.onRecord(ref)
                      : null,
                  child: Text(
                    record?.name ??
                        (state.connectionState != ConnectionState.done
                            ? '正在读取关联名称…'
                            : state.hasError
                            ? '关联名称暂时不可用'
                            : '关联目标已不可用'),
                  ),
                );
              },
            ),
        ],
      );
    },
  );
  @override
  Widget build(BuildContext context) {
    final d = widget.item.proposed,
        r = widget.review,
        c = UiPalette.of(context),
        shown = <String>{},
        links = <String>{};
    final sections = <Widget>[];
    for (final raw in d.definition['sections'] as List? ?? []) {
      if (raw is! Map) continue;
      final title = raw['title'] as String? ?? '内容';
      if (raw['kind'] == 'fields') {
        final keys = List<String>.from(raw['keys'] as List? ?? []);
        shown.addAll(keys);
        sections.add(proposalSection(context, title, _fields(keys)));
      } else if (raw['kind'] == 'entries' && raw['key'] is String) {
        final key = raw['key'] as String;
        shown.add(key);
        sections.add(
          proposalSection(context, title, LibraryEntryTimeline(r.values[key])),
        );
      } else if (raw['kind'] == 'text' && raw['key'] is String) {
        final key = raw['key'] as String;
        shown.add(key);
        if (raw['formatKey'] is String) shown.add(raw['formatKey'] as String);
        sections.add(
          proposalSection(
            context,
            title,
            LibraryDocument(
              body: r.values[key]?.toString() ?? '',
              format: r.values[raw['formatKey']]?.toString() ?? 'plain',
            ),
          ),
        );
      } else if (raw['kind'] == 'relations' && raw['key'] is String) {
        final key = raw['key'] as String;
        links.add(key);
        if (r.relations[key]?.isNotEmpty == true) {
          sections.add(proposalSection(context, title, _links(key)));
        }
      }
    }
    final extras = workspaceFields(
      d,
    ).map((f) => f['key'] as String).where((k) => !shown.contains(k)).toList();
    if (extras.isNotEmpty) {
      sections.add(proposalSection(context, '资料内容', _fields(extras)));
    }
    for (final key in r.values.keys.where(
      (k) => !shown.contains(k) && !extras.contains(k),
    )) {
      sections.add(
        proposalSection(
          context,
          '保留的内容',
          SelectableText(
            proposalValue(r.values[key]),
            style: libraryText(context, 14),
          ),
        ),
      );
    }
    for (final key in r.relations.keys.where((k) => !links.contains(k))) {
      sections.add(proposalSection(context, '关联资料', _links(key)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              r.name,
              style: libraryText(context, 22, weight: FontWeight.w700),
            ),
            ProposalPill(d.record.type.name),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          widget.catalog.directories
                  .where((x) => x.id == r.directoryId)
                  .firstOrNull
                  ?.name ??
              (r.directoryId == null ? '未分类' : '原目录已移除，请重新核对'),
          style: libraryText(context, 13, color: c.muted),
        ),
        if (r.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText(
              r.description,
              style: libraryText(context, 14, height: 1.9),
            ),
          ),
        if (d.templateState != WorkspaceTemplateState.available)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '模板已停用或缺失，按提交时的结构查看，不会改用当前新模板。',
              style: libraryText(context, 13, color: c.warning, height: 1.8),
            ),
          ),
        ...sections,
        if (r.tagIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final id in r.tagIds)
                  ProposalPill(
                    widget.catalog.tags
                            .where((t) => t.id == id)
                            .firstOrNull
                            ?.name ??
                        d.record.tags
                            .where((t) => t.id == id)
                            .firstOrNull
                            ?.name ??
                        '已移除标签',
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
