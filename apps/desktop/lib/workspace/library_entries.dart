import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_entries.dart';

class LibraryEntryTimeline extends StatelessWidget {
  const LibraryEntryTimeline(this.value, {super.key});
  final Object? value;
  @override
  Widget build(BuildContext context) {
    List<WorkspaceRepeatedEntry> entries;
    try {
      entries = WorkspaceRepeatedEntry.read(value);
    } on FormatException {
      return SelectableText(const JsonEncoder.withIndent('  ').convert(value));
    }
    final c = UiPalette.of(context);
    if (entries.isEmpty) {
      return Text('尚未添加经历。', style: libraryText(context, 14, color: c.muted));
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 18, 0, 12),
      padding: const EdgeInsets.only(left: 25),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, entry) in entries.indexed)
            Padding(
              key: ValueKey('library-timeline-${entry.id}'),
              padding: EdgeInsets.only(
                bottom: index + 1 < entries.length ? 28 : 0,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: -30,
                    top: 6,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.line, width: 2),
                        boxShadow: [
                          BoxShadow(color: c.timelineRing, spreadRadius: 1),
                        ],
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (entry.period.isNotEmpty)
                        SelectableText(
                          entry.label('period') ==
                                  WorkspaceRepeatedEntry.labels['period']
                              ? entry.period
                              : '${entry.label('period')}：${entry.period}',
                          style: libraryText(context, 13, color: c.muted),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: SelectableText(
                          entry.fieldIds.containsKey('title')
                              ? entry.title
                              : '经历（仅保留部分字段）',
                          style: libraryText(
                            context,
                            16,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (entry.detail.isNotEmpty) ...[
                        if (entry.label('detail') !=
                            WorkspaceRepeatedEntry.labels['detail'])
                          Text(
                            entry.label('detail'),
                            style: libraryText(context, 13, color: c.muted),
                          ),
                        SelectableText(
                          entry.detail,
                          style: libraryText(context, 14),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Draft changes stay in the parent form; stable keyed rows keep selection,
/// IME composition and controllers when moving an entry within a collection.
class LibraryEntriesEditor extends StatefulWidget {
  const LibraryEntriesEditor({
    super.key,
    required this.fieldKey,
    required this.label,
    required this.entries,
    required this.onChanged,
    required this.enabled,
    this.errors = const {},
    this.canAdd = true,
  });
  final String fieldKey, label;
  final List<WorkspaceRepeatedEntry> entries;
  final ValueChanged<List<WorkspaceRepeatedEntry>> onChanged;
  final bool enabled, canAdd;
  final Map<String, String> errors;
  @override
  State<LibraryEntriesEditor> createState() => _LibraryEntriesEditorState();
}

class _LibraryEntriesEditorState extends State<LibraryEntriesEditor> {
  String? _newId;
  void _move(int from, int to) {
    final next = List.of(widget.entries);
    next.insert(to, next.removeAt(from));
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.label,
          style: libraryText(context, 13, weight: FontWeight.w600),
        ),
        if (widget.errors[widget.fieldKey] case final message?)
          Text(message, style: libraryText(context, 13, color: c.danger)),
        if (widget.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '尚未添加经历。',
              style: libraryText(context, 13, color: c.muted),
            ),
          ),
        for (final (index, entry) in widget.entries.indexed)
          _EntryFields(
            key: ValueKey(entry.id),
            fieldKey: widget.fieldKey,
            entry: entry,
            ordinal: index + 1,
            enabled: widget.enabled,
            errors: widget.errors,
            focusOnMount: entry.id == _newId,
            onChanged: (value) {
              final next = List.of(widget.entries);
              next[index] = value;
              widget.onChanged(next);
            },
            onUp: index > 0 ? () => _move(index, index - 1) : null,
            onDown: index + 1 < widget.entries.length
                ? () => _move(index, index + 1)
                : null,
            onRemove: () =>
                widget.onChanged(List.of(widget.entries)..removeAt(index)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButton(
            key: ValueKey('library-entry-add-${widget.fieldKey}'),
            kind: DesktopButtonKind.quiet,
            onPressed: widget.enabled && widget.canAdd
                ? () {
                    final entry = WorkspaceRepeatedEntry.empty();
                    _newId = entry.id;
                    widget.onChanged([...widget.entries, entry]);
                  }
                : null,
            leading: const Icon(Icons.add, size: 16),
            child: const Text('添加一段'),
          ),
        ),
        if (!widget.canAdd)
          Text(
            '每项资料最多200个字段，每段经历占3个字段；只读经历会保留原文。',
            style: libraryText(context, 13, color: c.muted),
          ),
      ],
    );
  }
}

class _EntryFields extends StatefulWidget {
  const _EntryFields({
    super.key,
    required this.fieldKey,
    required this.entry,
    required this.ordinal,
    required this.enabled,
    required this.errors,
    required this.focusOnMount,
    required this.onChanged,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });
  final String fieldKey;
  final WorkspaceRepeatedEntry entry;
  final int ordinal;
  final bool enabled, focusOnMount;
  final Map<String, String> errors;
  final ValueChanged<WorkspaceRepeatedEntry> onChanged;
  final VoidCallback? onUp, onDown;
  final VoidCallback onRemove;
  @override
  State<_EntryFields> createState() => _EntryFieldsState();
}

class _EntryFieldsState extends State<_EntryFields> {
  late final _text = {
    for (final part in widget.entry.activeParts)
      part: TextEditingController(text: widget.entry.toJson()[part] as String),
  };
  final _titleFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _titleFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    _titleFocus.dispose();
    super.dispose();
  }

  Widget _field(String part, String label) =>
      !widget.entry.fieldIds.containsKey(part)
      ? Text(
          '$label已移除',
          style: libraryText(context, 13, color: UiPalette.of(context).muted),
        )
      : DesktopTextField(
          key: ValueKey(
            'library-entry-${widget.fieldKey}-${widget.entry.id}-$part',
          ),
          controller: _text[part],
          focusNode: part == 'title' ? _titleFocus : null,
          enabled: widget.enabled,
          minLines: part == 'detail' ? 2 : 1,
          maxLines: part == 'detail' ? 5 : 1,
          onChanged: (value) =>
              widget.onChanged(widget.entry.withText(part, value)),
          decoration: InputDecoration(
            labelText: widget.entry.label(part),
            errorText:
                widget.errors['${widget.fieldKey}:${widget.entry.id}:$part'],
          ),
        );
  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('library-entry-row-${widget.fieldKey}-${widget.entry.id}'),
    padding: const EdgeInsets.symmetric(vertical: 15),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '第${widget.ordinal}段',
              style: libraryText(
                context,
                12,
                color: UiPalette.of(context).muted,
              ),
            ),
            for (final (label, action, callback) in [
              ('上移', 'up', widget.onUp),
              ('下移', 'down', widget.onDown),
              ('移除', 'remove', widget.onRemove),
            ])
              DesktopButton(
                key: ValueKey('library-entry-$action-${widget.entry.id}'),
                kind: DesktopButtonKind.quiet,
                onPressed: widget.enabled ? callback : null,
                fontSize: 12,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                child: Text(label),
              ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, bounds) =>
              bounds.maxWidth >= 480 &&
                  MediaQuery.textScalerOf(context).scale(1) < 1.6
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _field('title', '经历名称')),
                    const SizedBox(width: 10),
                    Expanded(child: _field('period', '经历时间')),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field('title', '经历名称'),
                    const SizedBox(height: 10),
                    _field('period', '经历时间'),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        _field('detail', '经历说明'),
      ],
    ),
  );
}
