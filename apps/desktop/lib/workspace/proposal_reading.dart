import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_document.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'workspace_entries.dart';
import 'library_file_dialogs.dart';
import 'template_record_content.dart';
import 'proposal_original_reading.dart';
import 'proposal_reading_state.dart';

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
  Widget build(BuildContext context) =>
      LibraryPill(label, color: color, background: background);
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

class ProposalRelationChanges extends StatelessWidget {
  const ProposalRelationChanges({
    super.key,
    required this.before,
    required this.after,
    required this.source,
  });
  final WorkspaceDetail before;
  final WorkspaceProposalItemReview after;
  final WorkspaceRelationSource source;
  @override
  Widget build(BuildContext context) {
    final keys = {...before.relations.keys, ...after.relations.keys}.where((
      key,
    ) {
      final old = (before.relations[key] ?? []).toSet(),
          next = (after.relations[key] ?? []).toSet();
      return old.length != next.length || !old.containsAll(next);
    }).toList();
    if (keys.isEmpty) return const SizedBox.shrink();
    final refs = <WorkspaceRecordRef>{
      for (final relationKey in keys) ...{
        ...?before.relations[relationKey],
        ...?after.relations[relationKey],
      },
    };
    return FutureBuilder<List<WorkspaceRecordSummary>>(
      future: source.readSummaries(refs),
      builder: (context, result) {
        String names(List<WorkspaceRecordRef>? values) =>
            values == null || values.isEmpty
            ? '未关联'
            : values
                  .map(
                    (ref) =>
                        result.data
                            ?.where((r) => r.ref == ref)
                            .firstOrNull
                            ?.name ??
                        (result.connectionState != ConnectionState.done
                            ? '正在读取关联名称…'
                            : result.hasError
                            ? '关联名称暂时不可用'
                            : '关联目标已不可用'),
                  )
                  .join('、');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final key in keys)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: ProposalDiff(
                  label:
                      '关联：${(before.definition['relations'] as List? ?? []).cast<Map>().where((r) => r['key'] == key).firstOrNull?['label'] ?? key}',
                  before: names(before.relations[key]),
                  after: names(after.relations[key]),
                ),
              ),
          ],
        );
      },
    );
  }
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
    this.onFile,
    this.changedKeys = const {},
    this.passwordInput,
    this.readPendingFile,
    this.readStoredFile,
    this.originalsEnabled = true,
    this.readingState,
  });
  final Widget? passwordInput;
  final ProposalPendingFileReader? readPendingFile;
  final ProposalStoredFileReader? readStoredFile;
  final bool originalsEnabled;
  final ProposalReadingState? readingState;
  final Set<String> changedKeys;
  final WorkspaceProposalItem item;
  final WorkspaceProposalItemReview review;
  final WorkspaceCatalog catalog;
  final WorkspaceRelationSource relations;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final bool enabled;
  final Future<void> Function(String attachmentKey, int version)? onFile;
  @override
  State<ProposalItemReading> createState() => _ProposalItemReadingState();
}

class _ProposalItemReadingState extends State<ProposalItemReading> {
  DocumentReadingController? _ownedReading;
  DocumentReadingController get _reading =>
      widget.readingState?.document ??
      (_ownedReading ??= DocumentReadingController());
  @override
  void dispose() {
    _ownedReading?.dispose();
    super.dispose();
  }

  Widget _attachment(WorkspaceProposalAttachment a) =>
      ProposalAttachmentReading(
        key: ValueKey((
          widget.item.id,
          widget.item.originalProposalVersion,
          a.key,
        )),
        attachment: a,
        onFile: widget.onFile,
        readFile: widget.readPendingFile,
        originalsEnabled: widget.originalsEnabled,
        readingState: widget.readingState,
        enabled: widget.enabled,
      );

  @override
  Widget build(BuildContext context) {
    final d = widget.item.proposed,
        r = widget.review,
        c = UiPalette.of(context);
    final preview = proposalReadingDetail(widget.item, r);
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
        if (r.description.isNotEmpty && widget.item.credential == null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText(
              r.description,
              style: libraryText(context, 14, height: 1.9),
            ),
          ),
        if (d.templateState != WorkspaceTemplateState.available)
          Text(
            '模板已停用或缺失，按保留的内容显示。',
            style: libraryText(context, 13, color: c.warning),
          ),
        TemplateRecordContent(
          key: ValueKey('proposal-template-${widget.item.id}'),
          detail: preview,
          relations: widget.relations,
          onOpen: widget.enabled ? widget.onRecord : null,
          documentController: _reading,
          credentialIncludesRelations: false,
          changedKeys: widget.changedKeys,
          fileBuilder: (fieldKey) {
            final attachment = widget.item.attachments
                .where((a) => a.templateField == fieldKey)
                .firstOrNull;
            if (attachment != null) return _attachment(attachment);
            final ref = preview.values[fieldKey];
            if (ref is Map && widget.readStoredFile != null) {
              try {
                final file = WorkspaceFileRef.fromJson(ref);
                return ProposalOriginalReading(
                  key: ValueKey((widget.item.id, fieldKey, file)),
                  enabled: widget.originalsEnabled,
                  readingState: widget.readingState?.child(
                    'stored:$fieldKey:${file.id}:${file.version}',
                  ),
                  load: (page) =>
                      widget.readStoredFile!(preview, fieldKey, file, page),
                );
              } on WorkspaceFailure {
                /* Show an explicit unavailable file below. */
              }
            }
            return const Text('原文件预览暂不可用。');
          },
          credentialBuilder: (_) {
            final credential = widget.item.credential!;
            return Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SelectableText(
                      '账号：${credential.account.isEmpty ? '未注明' : credential.account}',
                      style: libraryText(context, 15),
                    ),
                  ),
                  if (credential.source == 'owner')
                    widget.passwordInput ??
                        Text(credential.ready ? '密码已填写' : '待填写密码')
                  else ...[
                    Text(
                      credential.fileName ?? '••••••••',
                      style: libraryText(context, 16),
                    ),
                    Text(
                      credential.source == 'agentFile' ? '文件已提供' : '凭证已提供',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                  ],
                  if (credential.contextExposed)
                    Text(
                      'AI已提供此密码或凭证，内容可能已进入会话上下文。',
                      style: libraryText(context, 13, color: c.warning),
                    ),
                ],
              ),
            );
          },
        ),
        for (final a in widget.item.attachments.where(
          (a) => a.templateField == null,
        ))
          proposalSection(context, a.name, _attachment(a)),
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

/// New-file and modification approvals share the same human-readable originals.
class ProposalAttachmentReading extends StatefulWidget {
  const ProposalAttachmentReading({
    super.key,
    required this.attachment,
    this.onFile,
    this.enabled = true,
    this.readFile,
    this.originalsEnabled = true,
    this.readingState,
  });
  final WorkspaceProposalAttachment attachment;
  final ProposalPendingFileReader? readFile;
  final bool originalsEnabled;
  final ProposalReadingState? readingState;
  final Future<void> Function(String attachmentKey, int version)? onFile;
  final bool enabled;
  @override
  State<ProposalAttachmentReading> createState() =>
      _ProposalAttachmentReadingState();
}

class _ProposalAttachmentReadingState extends State<ProposalAttachmentReading> {
  late int _selected;
  @override
  void initState() {
    super.initState();
    _selected =
        widget.readingState?.selectedOriginals[widget.attachment.key] ??
        widget.attachment.currentVersion ??
        (widget.attachment.previous != null ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final enabled = widget.enabled, onFile = widget.onFile;
    if (widget.readFile != null) {
      final available = [
        if (a.previous != null) 0,
        for (final (index, _) in a.versions.indexed) index + 1,
      ];
      if (!available.contains(_selected)) _selected = available.first;
      final original = _selected == 0 ? a.previous! : a.versions[_selected - 1];
      String label(int version) => version == 0
          ? '原文件'
          : a.versions[version - 1].label.isNotEmpty
          ? a.versions[version - 1].label
          : a.versions[version - 1].filename;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a.description.isNotEmpty) Text(a.description),
          if (a.currentVersion == null) const Text('只补充历史版本，当前文件保持不变。'),
          if (available.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final version in available)
                    ChoiceChip(
                      showCheckmark: false,
                      selected: _selected == version,
                      onSelected: enabled
                          ? (_) => setState(() {
                              _selected = version;
                              widget.readingState?.selectedOriginals[a.key] =
                                  version;
                            })
                          : null,
                      label: Text(
                        '${label(version)}${a.currentVersion == version ? ' · 当前' : ''}',
                      ),
                    ),
                ],
              ),
            ),
          if (original.sourceNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(original.sourceNote),
            ),
          ProposalOriginalReading(
            key: ValueKey((
              a.key,
              _selected,
              original.filename,
              original.byteLength,
            )),
            enabled: widget.originalsEnabled,
            readingState: widget.readingState?.child(
              'pending:${a.key}:$_selected',
            ),
            load: (page) => widget.readFile!(a.key, _selected, page),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (a.existingName.isNotEmpty) Text('补充到已有附件：${a.existingName}'),
        if (a.previous case final previous?) ...[
          LibraryFileSummary(
            label: '原当前文件',
            filename: previous.filename,
            mediaType: previous.mediaType,
            byteLength: previous.byteLength,
          ),
          DesktopButton(
            kind: DesktopButtonKind.quiet,
            onPressed: enabled && onFile != null
                ? () => onFile(a.key, 0)
                : null,
            child: const Text('查看原当前文件'),
          ),
        ],
        if (a.currentVersion == null) const Text('以下原文只补入历史，当前文件保持不变。'),
        if (a.description.isNotEmpty) Text(a.description),
        for (final (index, v) in a.versions.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LibraryFileSummary(
                  label:
                      '${v.label.isEmpty ? '提交的原文${index + 1}' : v.label}${a.currentVersion == index + 1 ? ' · 保存为当前版本' : ' · 保留为历史版本'}',
                  filename: v.filename,
                  mediaType: v.mediaType,
                  byteLength: v.byteLength,
                ),
                if (v.sourceNote.isNotEmpty)
                  SelectableText('来源依据：${v.sourceNote}'),
                DesktopButton(
                  kind: DesktopButtonKind.quiet,
                  onPressed: enabled && onFile != null
                      ? () => onFile(a.key, index + 1)
                      : null,
                  child: const Text('查看这份原文'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Project the complete submitted result without changing the reviewed command.
/// Older field-change proposals carry only changed values; their retained
/// baseline fills the unchanged fields, including individual timeline leaves.
WorkspaceDetail proposalReadingDetail(
  WorkspaceProposalItem item,
  WorkspaceProposalItemReview review,
) {
  final d = item.proposed;
  final values = <String, Object?>{
    if (item.beforeState == WorkspaceProposalBeforeState.available)
      ...?item.before?.values,
    ...d.values,
    ...review.values,
  };
  final overrides = <String, Map<String, Object?>?>{...d.fieldOverrides};
  final ids = <String, String>{...d.fieldIds};
  for (final change in item.changes) {
    if (change.entryId == null) {
      if (change.intent == WorkspaceProposalFieldIntent.remove) {
        values.remove(change.key);
        ids.remove(change.key);
        overrides[change.key] = null;
      } else if (change.definition != null) {
        overrides[change.key] = {...change.definition!, 'key': change.key};
      }
      continue;
    }
    if (!review.values.containsKey(change.reviewKey) &&
        change.intent != WorkspaceProposalFieldIntent.remove) {
      continue;
    }
    values.remove(change.reviewKey);
    final rows = WorkspaceRepeatedEntry.read(
      values[change.key],
    ).map((e) => e.toJson()).toList();
    var index = rows.indexWhere((row) => row['entryId'] == change.entryId);
    if (index < 0 && change.intent == WorkspaceProposalFieldIntent.add) {
      rows.add({
        'entryId': change.entryId,
        'fieldIds': <String, String>{},
        for (final part in WorkspaceRepeatedEntry.parts) part: '',
      });
      index = rows.length - 1;
    }
    if (index < 0) continue;
    final row = Map<String, Object?>.from(rows[index]);
    final leaf = change.leaf!;
    final fieldIds = Map<String, String>.from(row['fieldIds'] as Map);
    final definitions = Map<String, Object?>.from(
      row['definitions'] as Map? ?? {},
    );
    if (change.intent == WorkspaceProposalFieldIntent.remove) {
      fieldIds.remove(leaf);
      row[leaf] = '';
      definitions.remove(leaf);
    } else {
      row[leaf] = review.values[change.reviewKey];
      fieldIds[leaf] =
          fieldIds[leaf] ?? 'proposal:${item.id}:${change.reviewKey}';
      if (change.definition != null) definitions[leaf] = change.definition;
    }
    row['fieldIds'] = fieldIds;
    row['definitions'] = definitions;
    rows[index] = row;
    values[change.key] = rows
        .where((row) => (row['fieldIds'] as Map).isNotEmpty)
        .toList();
  }
  return WorkspaceDetail(
    record: d.record,
    version: d.version,
    templateState: d.templateState,
    definition: d.definition,
    values: values,
    relations:
        item.before != null &&
            d.definition['templateVersion'] == null &&
            review.relations.isEmpty
        ? item.before!.relations
        : review.relations,
    fieldIds: ids,
    fieldOverrides: overrides,
    retainedFields: d.retainedFields,
    retainedRelations: d.retainedRelations,
  );
}

/// Both sides use the library's plugin display; the proposal adds only labels
/// and change markers. Metadata edits are reflected in the complete after view.
class ProposalItemComparison extends StatelessWidget {
  const ProposalItemComparison({
    super.key,
    required this.item,
    required this.review,
    required this.catalog,
    required this.relations,
    required this.onRecord,
    required this.enabled,
    this.onFile,
    this.readPendingFile,
    this.readStoredFile,
    this.originalsEnabled = true,
    this.readingState,
  });
  final WorkspaceProposalItem item;
  final WorkspaceProposalItemReview review;
  final WorkspaceCatalog catalog;
  final WorkspaceRelationSource relations;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final bool enabled;
  final Future<void> Function(String, int)? onFile;
  final ProposalPendingFileReader? readPendingFile;
  final ProposalStoredFileReader? readStoredFile;
  final bool originalsEnabled;
  final ProposalReadingState? readingState;

  @override
  Widget build(BuildContext context) {
    final before = item.before!;
    final afterDetail = proposalReadingDetail(item, review);
    final keys = <String>{
      for (final key in {...before.values.keys, ...afterDetail.values.keys})
        if (jsonEncode(before.values[key]) !=
            jsonEncode(afterDetail.values[key]))
          key,
    };
    final labels = <String>[
      if (before.record.name != review.name) '资料名称',
      if (before.record.description != review.description) '用途说明',
      for (final key in keys)
        workspaceFields(
                  item.proposed,
                ).where((f) => f['key'] == key).firstOrNull?['label']
                as String? ??
            key,
      if (jsonEncode({
            for (final e in before.relations.entries)
              e.key: e.value.map((r) => r.key).toList(),
          }) !=
          jsonEncode({
            for (final e in afterDetail.relations.entries)
              e.key: e.value.map((r) => r.key).toList(),
          }))
        '关联资料',
      if (before.record.directoryId != review.directoryId) '目录',
      if (!setEquals(
        before.record.tags.map((t) => t.id).toSet(),
        review.tagIds.toSet(),
      ))
        '标签',
      if (item.attachments.isNotEmpty) '文件',
    ];
    Widget panel(String label, bool after) => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: UiPalette.of(context).line),
        borderRadius: BorderRadius.circular(8),
        color: after
            ? UiPalette.of(context).successSurface
            : UiPalette.of(context).rail,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: libraryText(context, 14, weight: FontWeight.w700)),
          const SizedBox(height: 16),
          if (!after &&
              item.beforeState != WorkspaceProposalBeforeState.available)
            const Text('修改前的内容暂不可用，请重新核对。')
          else
            ProposalItemReading(
              item: after
                  ? item
                  : WorkspaceProposalItem(id: item.id, proposed: before),
              review: after
                  ? review
                  : WorkspaceProposalItemReview.fromItem(
                      WorkspaceProposalItem(id: item.id, proposed: before),
                    ),
              catalog: catalog,
              relations: relations,
              onRecord: onRecord,
              enabled: enabled,
              changedKeys: after ? keys : const {},
              onFile: after ? onFile : null,
              readPendingFile: after ? readPendingFile : null,
              readStoredFile: readStoredFile,
              originalsEnabled: originalsEnabled,
              readingState: readingState?.child(after ? 'after' : 'before'),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          labels.isEmpty ? '没有内容变化' : '本次修改：${labels.join('、')}',
          style: libraryText(context, 14, color: UiPalette.of(context).accent),
        ),
        if (item.changes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final change in item.changes)
                  ProposalPill(
                    '${switch (change.intent) {
                      WorkspaceProposalFieldIntent.add => '新增',
                      WorkspaceProposalFieldIntent.replace => '替换',
                      WorkspaceProposalFieldIntent.remove => '删除',
                      WorkspaceProposalFieldIntent.correct => '修改',
                    }}：${change.definition?['label'] ?? change.label}',
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, bounds) =>
              bounds.maxWidth < 780 ||
                  MediaQuery.textScalerOf(context).scale(1) >= 1.6
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    panel('修改前', false),
                    const SizedBox(height: 16),
                    panel('修改后', true),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: panel('修改前', false)),
                    const SizedBox(width: 16),
                    Expanded(child: panel('修改后', true)),
                  ],
                ),
        ),
      ],
    );
  }
}
