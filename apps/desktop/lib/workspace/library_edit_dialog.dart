import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

Future<WorkspaceRecordRef?> showLibraryEditor(
  BuildContext context,
  LibraryController controller, {
  WorkspaceDetail? detail,
}) async {
  final catalog = controller.catalog;
  if (catalog == null) return null;
  var type = detail?.record.type;
  type ??= await showDesktopDialog<WorkspaceType>(
    context,
    builder: (context) => DesktopDialog(
      title: const Text('添加资料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final candidate in catalog.types.where(
            (t) => ['server', 'service', 'generic'].contains(t.id),
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DesktopButton(
                onPressed: () => Navigator.pop(context, candidate),
                leading: RecordIcon(candidate),
                padding: const EdgeInsets.all(14),
                alignment: Alignment.centerLeft,
                child: Text(candidate.name),
              ),
            ),
        ],
      ),
      actions: [
        DesktopButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  if (type == null || !context.mounted) return null;
  Map<String, Object?> definition;
  try {
    definition =
        detail?.definition ?? await controller.source.loadTemplate(type.id);
  } on WorkspaceFailure catch (failure) {
    if (!context.mounted) return null;
    await showDesktopDialog<void>(
      context,
      builder: (context) => DesktopDialog(
        title: const Text('暂时无法打开表单'),
        content: Text(failure.message),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    return null;
  }
  if (!context.mounted) return null;
  return showDesktopDialog<WorkspaceRecordRef>(
    context,
    builder: (_) => _Editor(
      controller: controller,
      type: type!,
      definition: definition,
      detail: detail,
    ),
  );
}

class _Editor extends StatefulWidget {
  const _Editor({
    required this.controller,
    required this.type,
    required this.definition,
    this.detail,
  });
  final LibraryController controller;
  final WorkspaceType type;
  final Map<String, Object?> definition;
  final WorkspaceDetail? detail;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final TextEditingController _name, _description;
  final _fields = <String, TextEditingController>{};
  final _tags = <String>{};
  String? _directory;
  bool _dirty = false, _discard = false, _saving = false;
  WorkspaceFailure? _failure;
  static int _operation = 0;
  @override
  void initState() {
    super.initState();
    final detail = widget.detail;
    _name = TextEditingController(text: detail?.record.name ?? '');
    _description = TextEditingController(
      text: detail?.record.description ?? '',
    );
    _directory =
        detail?.record.directoryId ?? widget.controller.query.directoryId;
    if (['all', 'unfiled'].contains(_directory)) _directory = null;
    _tags.addAll(detail?.record.tags.map((t) => t.id) ?? []);
    for (final field in widget.definition['fields'] as List? ?? []) {
      if (field['type'] == 'entries') continue;
      final key = field['key'] as String;
      _fields[key] = TextEditingController(
        text: detail?.values[key]?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _changed(String _) {
    setState(() => _dirty = true);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failure = null;
    });
    final detail = widget.detail;
    final catalog = widget.controller.catalog!;
    final values = {
      for (final entry in _fields.entries) entry.key: entry.value.text,
    };
    final id = 'library-form-${_operation++}';
    WorkspaceSaveResult result;
    try {
      result = detail == null
          ? await widget.controller.source.createRecord(
              WorkspaceCreate(
                operationId: id,
                typeId: widget.type.id,
                name: _name.text,
                description: _description.text,
                directoryId: _directory,
                tagIds: _tags,
                values: values,
              ),
            )
          : await widget.controller.save(
              WorkspaceEdit(
                operationId: id,
                expectedVersion: detail.version,
                record: detail.record.copyWith(
                  name: _name.text,
                  description: _description.text,
                  directoryId: _directory,
                  unfiled: _directory == null,
                  tags: catalog.tags.where((t) => _tags.contains(t.id)),
                ),
                values: values,
              ),
            );
    } on WorkspaceFailure catch (error) {
      result = WorkspaceRejected(error);
    } catch (_) {
      result = const WorkspaceRejected(
        WorkspaceFailure('unknown_outcome', '暂时无法确认保存结果，请重新读取核对，不要重复提交。'),
      );
    }
    if (!mounted) return;
    switch (result) {
      case WorkspaceSaved(:final detail):
        setState(() {
          _dirty = false;
          _saving = false;
        });
        // PopScope observes its new canPop before the explicit successful pop.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, detail.record.ref);
        });
      case WorkspaceRejected(:final failure):
        setState(() {
          _saving = false;
          _failure = failure;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.controller.catalog!, c = UiPalette.of(context);
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_saving) setState(() => _discard = true);
      },
      child: DesktopDialog(
        title: Text(
          widget.detail == null
              ? '添加${widget.type.name}'
              : '编辑${widget.type.name}',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopTextField(
              key: const ValueKey('library-edit-name'),
              controller: _name,
              enabled: !_saving,
              onChanged: _changed,
              decoration: InputDecoration(
                labelText: '名称',
                errorText: _failure?.fieldErrors['name'],
              ),
            ),
            const SizedBox(height: 18),
            DesktopTextField(
              key: const ValueKey('library-edit-description'),
              controller: _description,
              enabled: !_saving,
              onChanged: _changed,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: '用途说明',
                errorText: _failure?.fieldErrors['description'],
              ),
            ),
            const SizedBox(height: 18),
            DesktopSelect<String?>(
              value: _directory,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '资料目录'),
              items: [
                const DropdownMenuItem(value: null, child: Text('未分类')),
                for (final directory in catalog.directories.where(
                  (d) => !['all', 'unfiled'].contains(d.id),
                ))
                  DropdownMenuItem(
                    value: directory.id,
                    child: Text(directory.name),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _directory = value;
                      _dirty = true;
                    }),
            ),
            const SizedBox(height: 18),
            Text('标签', style: libraryText(context, 13, color: c.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final tag in catalog.tags)
                  LibraryTag(
                    tag.name,
                    selected: _tags.contains(tag.id),
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                            _tags.contains(tag.id)
                                ? _tags.remove(tag.id)
                                : _tags.add(tag.id);
                            _dirty = true;
                          }),
                  ),
              ],
            ),
            for (final field in widget.definition['fields'] as List? ?? [])
              if (_fields.containsKey(field['key'])) ...[
                const SizedBox(height: 18),
                DesktopTextField(
                  key: ValueKey('library-edit-${field['key']}'),
                  controller: _fields[field['key']],
                  enabled: !_saving,
                  onChanged: _changed,
                  minLines: field['type'] == 'multiline' ? 3 : 1,
                  maxLines: field['type'] == 'multiline' ? 6 : 1,
                  decoration: InputDecoration(
                    labelText:
                        '${field['label']}${field['required'] == true ? ' *' : ''}',
                    errorText: _failure?.fieldErrors[field['key']],
                  ),
                ),
              ],
          ],
        ),
        actions: [
          if (_failure != null)
            SizedBox(
              width: double.infinity,
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _failure!.message,
                  key: const ValueKey('library-edit-status'),
                  style: TextStyle(color: c.danger),
                ),
              ),
            ),
          if (_discard)
            SizedBox(
              width: double.infinity,
              child: Text(
                '尚有未保存的修改。可继续编辑，或放弃修改后关闭。',
                style: TextStyle(color: c.warning),
              ),
            ),
          if (_discard)
            DesktopButton(
              kind: DesktopButtonKind.danger,
              onPressed: _saving
                  ? null
                  : () {
                      setState(() => _dirty = false);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) Navigator.pop(context);
                      });
                    },
              child: const Text('放弃修改'),
            ),
          DesktopButton(
            onPressed: _saving
                ? null
                : () {
                    if (_dirty) {
                      setState(() => _discard = true);
                    } else {
                      Navigator.pop(context);
                    }
                  },
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('library-edit-save'),
            busy: _saving,
            kind: DesktopButtonKind.primary,
            onPressed: _failure?.code == 'unknown_outcome' ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
