import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'library_entries.dart';
import 'library_relation_picker.dart';
import 'workspace_entries.dart';
import 'workspace_source.dart';

class ProposalItemEditor extends StatefulWidget {
  const ProposalItemEditor({
    super.key,
    required this.item,
    required this.review,
    required this.catalog,
    required this.relations,
    required this.onSave,
    this.errors = const {},
  });
  final WorkspaceProposalItem item;
  final WorkspaceProposalItemReview review;
  final WorkspaceCatalog catalog;
  final WorkspaceRelationSource relations;
  final bool Function(WorkspaceProposalItemReview) onSave;
  final Map<String, String> errors;
  @override
  State<ProposalItemEditor> createState() => _ProposalItemEditorState();
}

class _ProposalItemEditorState extends State<ProposalItemEditor> {
  late final TextEditingController _name, _description;
  final _text = <String, TextEditingController>{};
  late final Map<String, String> _fieldErrors;
  final _entries = <String, List<WorkspaceRepeatedEntry>>{};
  late Map<String, List<WorkspaceRecordRef>> _relations;
  late Set<String> _tags;
  String? _directory, _error;
  bool get _new => widget.item.before == null;
  List<Map<String, Object?>> get _fields => _new
      ? workspaceFields(widget.item.proposed)
      : [
          for (final change in widget.item.changes)
            if (change.intent != WorkspaceProposalFieldIntent.remove)
              {
                ...?workspaceFields(
                  widget.item.proposed,
                ).where((f) => f['key'] == change.key).firstOrNull,
                ...?change.definition,
                'key': change.reviewKey,
                'proposalRootKey': change.key,
                'label': change.label,
                if (change.entryId != null)
                  'type':
                      change.definition?['type'] ??
                      (change.leaf == 'detail' ? 'multiline' : 'text'),
              },
        ];
  @override
  void initState() {
    super.initState();
    final r = widget.review;
    _fieldErrors = Map.of(widget.errors);
    _name = TextEditingController(text: r.name);
    _description = TextEditingController(text: r.description);
    _directory = r.directoryId;
    _tags = r.tagIds.toSet();
    _relations = {for (final e in r.relations.entries) e.key: List.of(e.value)};
    for (final f in _fields) {
      final key = f['key'] as String;
      if (f['type'] == 'entries') {
        try {
          _entries[key] = WorkspaceRepeatedEntry.read(r.values[key]);
        } on FormatException {
          /* Unknown original shape remains read-only. */
        }
      } else if (f['type'] != 'file' &&
          f['type'] != 'unknown' &&
          (r.values[key] == null || r.values[key] is String)) {
        _text[key] = TextEditingController(
          text: r.values[key] as String? ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请填写资料名称。');
      return;
    }
    final review = WorkspaceProposalItemReview(
      itemId: widget.review.itemId,
      name: _name.text,
      description: _description.text,
      directoryId: _directory,
      tagIds: _tags,
      values: {
        ...widget.review.values,
        for (final e in _text.entries) e.key: e.value.text,
        for (final e in _entries.entries)
          e.key: e.value.map((v) => v.toJson()).toList(),
      },
      relations: _relations,
    );
    if (!widget.onSave(review)) {
      setState(() => _error = '提案或读取状态已变化，编辑内容仍保留，请先重新核对。');
      return;
    }
    Navigator.pop(context);
  }

  Widget _field(Map<String, Object?> f) {
    final key = f['key'] as String, label = f['label'] as String? ?? key;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: _entries.containsKey(key)
          ? LibraryEntriesEditor(
              fieldKey: key,
              label: label,
              entries: _entries[key]!,
              onChanged: (v) => setState(() => _entries[key] = v),
              enabled: true,
              errors: _fieldErrors,
            )
          : _text.containsKey(key)
          ? DesktopTextField(
              key: ValueKey('proposal-edit-$key'),
              controller: _text[key],
              maxLines: f['type'] == 'multiline' ? 4 : 1,
              maxLength: 64000,
              onChanged: (_) => setState(() {
                _fieldErrors.remove(workspaceValueErrorKey(key));
                _fieldErrors.remove(key);
              }),
              decoration: InputDecoration(
                labelText: label,
                errorText:
                    _fieldErrors[workspaceValueErrorKey(key)] ??
                    _fieldErrors[key],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$label · 只读保留',
                  style: libraryText(
                    context,
                    13,
                    color: UiPalette.of(context).muted,
                  ),
                ),
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(widget.review.values[key]),
                  style: libraryText(context, 14),
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context),
        dirs = widget.catalog.directories
            .where((d) => !['all', 'unfiled'].contains(d.id))
            .toList();
    return DesktopDialog(
      title: const Text('编辑待审资料'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            Text(_error!, style: libraryText(context, 14, color: c.danger)),
          if (_new) ...[
            DesktopTextField(
              key: const ValueKey('proposal-edit-name'),
              controller: _name,
              maxLength: 160,
              onChanged: (_) => setState(() => _fieldErrors.remove('name')),
              decoration: InputDecoration(
                labelText: '资料名称',
                errorText: _fieldErrors['name'],
              ),
            ),
            const SizedBox(height: 16),
            DesktopTextField(
              key: const ValueKey('proposal-edit-description'),
              controller: _description,
              maxLength: 2000,
              maxLines: 3,
              onChanged: (_) =>
                  setState(() => _fieldErrors.remove('description')),
              decoration: InputDecoration(
                labelText: '用途说明',
                errorText: _fieldErrors['description'],
              ),
            ),
            const SizedBox(height: 16),
            DesktopSelect<String>(
              key: const ValueKey('proposal-edit-directory'),
              value: _directory ?? '',
              items: [
                const DropdownMenuItem(value: '', child: Text('未分类')),
                if (_directory != null && !dirs.any((d) => d.id == _directory))
                  DropdownMenuItem(
                    value: _directory,
                    child: const Text('原目录已移除，请重新选择'),
                  ),
                for (final d in dirs)
                  DropdownMenuItem(value: d.id, child: Text(d.name)),
              ],
              onChanged: (v) => setState(() => _directory = v == '' ? null : v),
            ),
            const SizedBox(height: 16),
            Text('标签', style: libraryText(context, 13, color: c.muted)),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in widget.catalog.tags)
                  DesktopButton(
                    key: ValueKey('proposal-edit-tag-${tag.id}'),
                    kind: DesktopButtonKind.quiet,
                    selected: _tags.contains(tag.id),
                    onPressed: () => setState(() {
                      if (!_tags.add(tag.id)) _tags.remove(tag.id);
                    }),
                    child: Text(tag.name),
                  ),
                for (final id in _tags.where(
                  (id) => !widget.catalog.tags.any((t) => t.id == id),
                ))
                  DesktopButton(
                    onPressed: () => setState(() => _tags.remove(id)),
                    child: const Text('移除已失效标签'),
                  ),
              ],
            ),
          ] else
            Text(
              '这里只修改提案明确列出的字段。资料名称、分类和关联保持当前内容。',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
          if (_fieldErrors['classification'] case final error?)
            Text(error, style: libraryText(context, 13, color: c.danger)),
          for (final f in _fields) _field(f),
          if (_new)
            for (final raw
                in widget.item.proposed.definition['relations'] as List? ?? [])
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: LibraryRelationPicker(
                  source: widget.relations,
                  typeId: widget.item.proposed.record.type.id,
                  relationKey: raw['key'] as String,
                  label: raw['label'] as String? ?? raw['key'] as String,
                  selected: _relations[raw['key']] ?? [],
                  errorText: _fieldErrors['relation:${raw['key']}'],
                  onChanged: (v) =>
                      setState(() => _relations[raw['key'] as String] = v),
                ),
              ),
        ],
      ),
      actions: [
        DesktopButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        DesktopButton(
          key: const ValueKey('proposal-edit-keep'),
          kind: DesktopButtonKind.primary,
          onPressed: _save,
          child: const Text('保留修改'),
        ),
      ],
    );
  }
}
