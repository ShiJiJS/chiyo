import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_entries.dart';
import 'workspace_source.dart';

enum LibraryEditConflictChoice { keepDraft, reload }

/// Comparison includes identities and shape. Map insertion order is irrelevant;
/// ordered fields/entries remain ordered. Callers exclude version/digest facts.
bool libraryEditorShapeEqual(Object? a, Object? b) {
  Object? ordered(Object? value) => switch (value) {
    Map() => {
      for (final key in (value.keys.cast<String>().toList()..sort()))
        key: ordered(value[key]),
    },
    List() => value.map(ordered).toList(),
    _ => value,
  };
  return jsonEncode(ordered(a)) == jsonEncode(ordered(b));
}

typedef LibraryEditReviewValue = ({String id, String label, String value});

List<LibraryEditReviewValue> libraryEditorReviewValues({
  required WorkspaceRecordSummary record,
  required Map<String, Object?> definition,
  required Map<String, Object?> values,
  required Map<String, List<WorkspaceRecordRef>> relations,
  required WorkspaceCatalog catalog,
  required Map<WorkspaceRecordRef, WorkspaceRecordSummary> targets,
}) {
  String value(Object? v) => v == null || v == ''
      ? '未填写'
      : v is String
      ? v
      : const JsonEncoder.withIndent('  ').convert(v);
  final fields = definition['fields'] as List? ?? [],
      rules = definition['relations'] as List? ?? [];
  String fieldValue(Map field) {
    final raw = values[field['key']];
    if (field['type'] != 'entries') return value(raw);
    try {
      final entries = WorkspaceRepeatedEntry.read(raw);
      return entries.isEmpty
          ? '没有经历条目'
          : [
              for (final (index, entry) in entries.indexed)
                '第${index + 1}条\n名称：${value(entry.title)}\n时间：${value(entry.period)}\n说明：${value(entry.detail)}',
            ].join('\n\n');
    } on FormatException {
      return '不可编辑的旧内容，继续保留当前原文。';
    }
  }

  const kinds = {
    'text': '文本',
    'url': '网址',
    'number': '数字',
    'date': '日期',
    'multiline': '多行文本',
    'entries': '经历条目',
    'file': '普通附件',
    'unknown': '旧内容',
  };
  String targetLabel(WorkspaceRecordRef ref) {
    final target = targets[ref];
    if (target == null) return '不可用目标（${ref.key}）';
    final ambiguous =
        targets.values.where((r) => r.name == target.name).length > 1;
    return '${target.name} · ${target.type.name}${ambiguous ? '（${ref.key}）' : ''}';
  }

  return [
    (id: 'name', label: '名称', value: value(record.name)),
    (id: 'description', label: '用途说明', value: value(record.description)),
    (
      id: 'directory',
      label: '目录',
      value: record.directoryId == null
          ? '未分类'
          : catalog.directories
                    .where((d) => d.id == record.directoryId)
                    .firstOrNull
                    ?.name ??
                '已移除目录',
    ),
    (
      id: 'tags',
      label: '标签',
      value: record.tags.isEmpty
          ? '无标签'
          : record.tags.map((t) => t.name).join('、'),
    ),
    for (final field in fields)
      if (field['type'] != 'file' && field['type'] != 'unknown')
        (
          id: 'field:${field['key']}',
          label: field['label'] as String,
          value: fieldValue(field as Map),
        ),
    for (final e in relations.entries)
      (
        id: 'relation:${e.key}',
        label:
            rules.where((r) => r['key'] == e.key).firstOrNull?['label']
                as String? ??
            '关联资料',
        value: e.value.isEmpty ? '无关联' : e.value.map(targetLabel).join('、'),
      ),
    (
      id: 'structure',
      label: '表单结构',
      value: [
        '资料类型：${record.type.name}',
        for (final f in fields)
          '${f['label']} · ${kinds[f['type']] ?? '旧内容'}${f['required'] == true ? ' · 必填' : ''}',
        for (final r in rules) '关联：${r['label']}',
      ].join('\n'),
    ),
  ];
}

Future<LibraryEditConflictChoice?> showLibraryEditConflict(
  BuildContext context, {
  required List<LibraryEditReviewValue> draft,
  required List<LibraryEditReviewValue> current,
  required String currentLabel,
  required bool compatible,
}) => showDesktopDialog<LibraryEditConflictChoice>(
  context,
  builder: (context) {
    final c = UiPalette.of(context),
        before = {for (final e in current) e.id: e},
        after = {for (final e in draft) e.id: e},
        keys = {...before.keys, ...after.keys},
        changed = keys.where((k) => before[k]?.value != after[k]?.value);
    Widget content(String title, String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: libraryText(context, 12, color: c.muted)),
        const SizedBox(height: 5),
        SelectableText(
          text.length > 2000
              ? '${text.substring(0, 2000)}\n（预览前2000字，原文保留）'
              : text,
          style: libraryText(context, 14, height: 1.7),
        ),
      ],
    );
    return DesktopDialog(
      width: 820,
      title: const Text('核对当前版本与草稿'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            currentLabel,
            style: libraryText(context, 14, weight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(
            compatible
                ? '核对以下差异。选择保留草稿后，下一次保存会以草稿替换这些当前内容。'
                : '当前字段、经历或分类已变化。请先保留所需内容，再重新载入表单；这会清空本次草稿。',
            style: libraryText(context, 14, height: 1.8, color: c.warning),
          ),
          const SizedBox(height: 10),
          Text(
            '此处只核对，不保存。附件和只读内容沿用当前版本。',
            style: libraryText(context, 13, height: 1.8, color: c.muted),
          ),
          if (changed.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Text('表单内容与当前版本一致。'),
            ),
          for (final key in changed)
            Container(
              key: ValueKey('library-edit-review-$key'),
              margin: const EdgeInsets.only(top: 20),
              padding: const EdgeInsets.only(top: 16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    after[key]?.label ?? before[key]!.label,
                    style: libraryText(context, 14, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  content('当前', before[key]?.value ?? '当前没有此字段'),
                  const SizedBox(height: 12),
                  content('草稿', after[key]?.value ?? '草稿没有此字段'),
                ],
              ),
            ),
        ],
      ),
      actions: [
        DesktopButton(
          key: const ValueKey('library-edit-review-back'),
          onPressed: () => Navigator.pop(context),
          child: const Text('返回草稿'),
        ),
        DesktopButton(
          key: const ValueKey('library-edit-review-reload'),
          onPressed: () =>
              Navigator.pop(context, LibraryEditConflictChoice.reload),
          child: const Text('清空草稿并载入当前表单'),
        ),
        if (compatible)
          DesktopButton(
            key: const ValueKey('library-edit-review-keep'),
            kind: DesktopButtonKind.primary,
            onPressed: () =>
                Navigator.pop(context, LibraryEditConflictChoice.keepDraft),
            child: const Text('保留草稿，按当前版本继续'),
          ),
      ],
    );
  },
);
