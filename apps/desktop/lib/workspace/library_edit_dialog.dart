import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_controller.dart';
import 'library_widgets.dart';
import 'library_relation_picker.dart';
import 'library_entries.dart';
import 'workspace_entries.dart';
import 'library_file_dialogs.dart';
import 'library_credential_editor.dart';
import 'workspace_source.dart';
import 'record_mutation.dart';
import 'library_edit_conflict.dart';

Future<WorkspaceRecordRef?> showLibraryEditor(
  BuildContext context,
  LibraryController controller, {
  WorkspaceDetail? detail,
  WorkspaceType? selectedType,
  WorkspaceLegacyTemplate? legacyTemplate,
  WorkspaceFilePicker? filePicker,
  WorkspaceCredentialPicker? credentialPicker,
}) async {
  final catalog = controller.catalog;
  if (catalog == null) return null;
  var type =
      detail?.record.type ??
      selectedType ??
      (legacyTemplate == null
          ? null
          : catalog.types.where((t) => t.id == 'generic').firstOrNull);
  type ??= await showDesktopDialog<WorkspaceType>(
    context,
    builder: (context) => DesktopDialog(
      title: const Text('添加资料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final candidate in catalog.creatableTypes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DesktopButton(
                key: ValueKey('library-new-type-${candidate.id}'),
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
  if (type.id == 'credential') {
    return showLibraryCredentialEditor(
      context,
      controller.source,
      catalog,
      ref: detail?.record.ref,
      picker: credentialPicker,
    );
  }
  if (type.id == 'file' && detail == null) {
    return showLibraryFileImport(
      context,
      controller.source,
      catalog,
      filePicker,
      controller.query.directoryId,
    );
  }
  Map<String, Object?> definition;
  try {
    if (legacyTemplate != null) {
      final current = await controller.source.legacyTemplates.read(
        legacyTemplate.id,
      );
      if (current.version != legacyTemplate.version) {
        throw const WorkspaceFailure('conflict', '旧版模板已变化，请重新读取并核对。');
      }
      definition = current.definition;
    } else {
      definition = detail == null
          ? await controller.source.loadTemplate(type.id)
          : workspaceEditingDefinition(detail);
    }
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
      filePicker: filePicker,
    ),
  );
}

class _Editor extends StatefulWidget {
  const _Editor({
    required this.controller,
    required this.type,
    required this.definition,
    this.detail,
    this.filePicker,
  });
  final LibraryController controller;
  final WorkspaceType type;
  final Map<String, Object?> definition;
  final WorkspaceDetail? detail;
  final WorkspaceFilePicker? filePicker;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final TextEditingController _name, _description;
  late WorkspaceType _type;
  late Map<String, Object?> _definition;
  late WorkspaceCatalog _catalog;
  WorkspaceDetail? _detail;
  bool _reviewing = false, _reviewOpen = false;
  final _fields = <String, TextEditingController>{};
  Set<String> get _documentFormats => {
    for (final section in _definition['sections'] as List? ?? [])
      if (section['kind'] == 'text' && section['formatKey'] is String)
        section['formatKey'] as String,
  };
  final _entries = <String, List<WorkspaceRepeatedEntry>>{};
  final _readOnlyEntries = <String, Object?>{};
  final _fileSelections = <String, WorkspaceFileCandidate>{};
  bool _pickingFile = false;
  final _tags = <String>{};
  final _relations = <String, List<WorkspaceRecordRef>>{};
  final _editedRelations = <String>{};
  String? _directory;
  bool _dirty = false, _discard = false;
  late final RecordMutation _mutation;
  bool get _saving => _mutation.busy;
  bool get _locked =>
      _mutation.frozen || _pickingFile || _reviewing || _reviewOpen;
  WorkspaceFailure? get _failure => _mutation.failure;
  String? _notice;
  void _mutationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _mutation = RecordMutation(widget.controller.source)
      ..addListener(_mutationChanged);
    _name = TextEditingController();
    _description = TextEditingController();
    _catalog = widget.controller.catalog!;
    _setForm(widget.detail, widget.definition, widget.type);
  }

  void _setForm(
    WorkspaceDetail? detail,
    Map<String, Object?> definition,
    WorkspaceType type,
  ) {
    final previous = _fields.values.toList();
    _fields.clear();
    _entries.clear();
    _readOnlyEntries.clear();
    _fileSelections.clear();
    _tags.clear();
    _relations.clear();
    _editedRelations.clear();
    _detail = detail;
    _definition = definition;
    _type = type;
    if (previous.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final c in previous) {
          c.dispose();
        }
      });
    }
    _name.text = detail?.record.name ?? '';
    _description.text = detail?.record.description ?? '';
    _directory = detail == null
        ? widget.controller.query.directoryId
        : detail.record.directoryId;
    if (['all', 'unfiled'].contains(_directory)) _directory = null;
    _tags.addAll(detail?.record.tags.map((t) => t.id) ?? []);
    for (final rule in _definition['relations'] as List? ?? []) {
      final key = rule['key'] as String;
      _relations[key] = List.of(detail?.relations[key] ?? []);
    }
    for (final field in _definition['fields'] as List? ?? []) {
      final key = field['key'] as String;
      if (['file', 'unknown'].contains(field['type'])) continue;
      if (field['type'] == 'entries') {
        try {
          final entries = WorkspaceRepeatedEntry.read(detail?.values[key]);
          if (entries.length > WorkspaceRepeatedEntry.maxEntriesPerField) {
            _readOnlyEntries[key] = detail?.values[key];
          } else {
            _entries[key] = entries;
          }
        } on FormatException {
          _readOnlyEntries[key] = detail?.values[key];
        }
        continue;
      }
      _fields[key] = TextEditingController(
        text:
            detail?.values[key]?.toString() ??
            (_documentFormats.contains(key) ? 'markdown' : ''),
      );
    }
    if (_fields.length +
            _entries.values.fold<int>(
              0,
              (sum, list) =>
                  sum +
                  list.fold<int>(0, (n, entry) => n + entry.fieldIds.length),
            ) >
        WorkspaceRepeatedEntry.maxLeavesPerRecord) {
      for (final key in _entries.keys) {
        _readOnlyEntries[key] = detail?.values[key];
      }
      _entries.clear();
    }
  }

  @override
  void dispose() {
    _mutation.dispose();
    _name.dispose();
    _description.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _changed(String _) {
    _mutation.edited();
    setState(() {
      _dirty = true;
      _notice = null;
    });
  }

  void _finish(WorkspaceRecordReceipt receipt) {
    setState(() {
      _dirty = false;
      _discard = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, receipt.ref);
    });
  }

  Future<void> _reconcile() async {
    final receipt = await _mutation.reconcile();
    if (!mounted) return;
    if (receipt != null) {
      _finish(receipt);
    } else if (!_mutation.uncertain) {
      setState(() => _notice = '已确认尚未提交。草稿已保留，可修改或重新保存。');
    }
  }

  Future<void> _reviewConflict() async {
    if (_locked || _failure?.code != 'conflict') return;
    setState(() {
      _reviewing = true;
      _notice = null;
    });
    try {
      final source = widget.controller.source, original = _detail;
      final fresh = original == null
          ? null
          : await source.readDetail(original.record.ref);
      if (!mounted) return;
      final catalog = await source.loadCatalog();
      if (!mounted) return;
      final legacyId = _definition['legacyTemplateId'] as String?;
      final definition = fresh != null
          ? workspaceEditingDefinition(fresh)
          : legacyId != null
          ? (await source.legacyTemplates.read(legacyId)).definition
          : await source.loadTemplate(_type.id);
      if (!mounted) return;
      final type =
          fresh?.record.type ??
          catalog.creatableTypes.where((t) => t.id == _type.id).firstOrNull;
      if (type == null) {
        throw const WorkspaceFailure(
          'template_unavailable',
          '原模板已不可用于新建；草稿仍保留，可返回后选择其他模板。',
        );
      }
      Map<String, Object?> shape(Map<String, Object?> d) => Map.of(d)
        ..remove('templateVersion')
        ..remove('packageDigest')
        ..remove('legacyTemplateVersion');
      bool entriesUnchanged() {
        if (original == null) return true;
        try {
          Map<String, Object?> identities(WorkspaceDetail d) => {
            for (final key in _entries.keys)
              key: {
                for (final entry in WorkspaceRepeatedEntry.read(d.values[key]))
                  entry.id: entry.fieldIds,
              },
          };
          return libraryEditorShapeEqual(
            identities(original),
            identities(fresh!),
          );
        } on FormatException {
          return false;
        }
      }

      final compatible =
          type.id == _type.id &&
          entriesUnchanged() &&
          libraryEditorShapeEqual(shape(definition), shape(_definition)) &&
          (original == null ||
              libraryEditorShapeEqual(original.fieldIds, fresh!.fieldIds)) &&
          (_directory == null ||
              catalog.directories.any((d) => d.id == _directory)) &&
          _tags.every((id) => catalog.tags.any((t) => t.id == id));
      final currentRecord =
          fresh?.record ??
          WorkspaceRecordSummary(
            ref: const WorkspaceRecordRef(
              WorkspaceRecordKind.information,
              'uncommitted-editor',
            ),
            name: '',
            description: '',
            type: type,
            updatedAt: DateTime.utc(2026),
          );
      final draftRecord = currentRecord.copyWith(
        name: _name.text,
        description: _description.text,
        directoryId: _directory,
        unfiled: _directory == null,
        tags: _catalog.tags.where((t) => _tags.contains(t.id)),
      );
      final draftRelations = {
        ...?fresh?.relations,
        for (final e in _relations.entries)
          if (original == null || _editedRelations.contains(e.key))
            e.key: e.value,
      };
      final targets = await source.readSummaries({
        ...?fresh?.relations.values.expand((r) => r),
        ...draftRelations.values.expand((r) => r),
      });
      if (!mounted) return;
      final names = {for (final t in targets) t.ref: t};
      setState(() {
        _reviewing = false;
        _reviewOpen = true;
      });
      final choice = await showLibraryEditConflict(
        context,
        currentLabel: fresh == null
            ? '当前模板：${type.name} · ${definition['legacyTemplateVersion'] ?? definition['templateVersion'] ?? '当前版本'}'
            : '当前资料：${fresh.record.name} · 第${fresh.version}版',
        compatible: compatible,
        current: libraryEditorReviewValues(
          record: currentRecord,
          definition: definition,
          values: fresh?.values ?? const {},
          relations: fresh?.relations ?? const {},
          catalog: catalog,
          targets: names,
        ),
        draft: libraryEditorReviewValues(
          record: draftRecord,
          definition: _definition,
          values: {
            ...?fresh?.values,
            for (final e in _fields.entries) e.key: e.value.text,
            for (final e in _entries.entries)
              e.key: [for (final v in e.value) v.toJson()],
          },
          relations: draftRelations,
          catalog: _catalog,
          targets: names,
        ),
      );
      if (!mounted || choice == null) return;
      setState(() {
        _catalog = catalog;
        if (choice == LibraryEditConflictChoice.reload) {
          _setForm(fresh, definition, type);
          _dirty = false;
          _discard = false;
          _notice = '已明确重新载入当前表单，尚未保存。';
        } else {
          _detail = fresh;
          _definition = definition;
          _type = type;
          if (fresh != null) {
            for (final key in _relations.keys) {
              if (!_editedRelations.contains(key)) {
                _relations[key] = List.of(fresh.relations[key] ?? []);
              }
            }
            for (final key in _readOnlyEntries.keys.toList()) {
              _readOnlyEntries[key] = fresh.values[key];
            }
          }
          _notice = '草稿已保留，按核对的当前版本继续；尚未保存。';
        }
        _mutation.acceptCurrentVersion();
      });
    } on WorkspaceFailure catch (e) {
      if (mounted) setState(() => _notice = e.message);
    } catch (_) {
      if (mounted) setState(() => _notice = '暂时无法核对当前版本，草稿仍保留，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _reviewOpen = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_mutation.canSubmit || _locked) return;
    _notice = null;
    final detail = _detail;
    final catalog = _catalog;
    final values = {
      for (final entry in _fields.entries) entry.key: entry.value.text,
      for (final entry in _entries.entries)
        entry.key: [for (final value in entry.value) value.toJson()],
    };
    final receipt = await _mutation.submit(
      WorkspaceOperationIntent(
        kind: detail == null
            ? WorkspaceOperationKind.create
            : WorkspaceOperationKind.edit,
        ref: detail?.record.ref,
        typeId: _type.id,
        expectedVersion: detail?.version,
        legacyTemplateId: detail == null
            ? _definition['legacyTemplateId'] as String?
            : null,
        legacyTemplateVersion: detail == null
            ? _definition['legacyTemplateVersion'] as int?
            : null,
      ),
      (id) async {
        final result = detail == null
            ? await widget.controller.source.createRecord(
                WorkspaceCreate(
                  operationId: id,
                  typeId: _type.id,
                  legacyTemplateId: _definition['legacyTemplateId'] as String?,
                  expectedLegacyVersion:
                      _definition['legacyTemplateVersion'] as int?,
                  fileSelections: {
                    for (final e in _fileSelections.entries)
                      e.key: e.value.selectionId,
                  },
                  expectedTemplateVersion:
                      _definition['templateVersion'] as String?,
                  expectedTemplateDigest:
                      _definition['packageDigest'] as String?,
                  name: _name.text,
                  description: _description.text,
                  directoryId: _directory,
                  tagIds: _tags,
                  values: values,
                  relations: _relations,
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
                  relations: {
                    for (final key in _editedRelations) key: _relations[key]!,
                  },
                ),
              );
        return switch (result) {
          WorkspaceSaved(:final detail) => WorkspaceRecordReceipt(
            ref: detail.record.ref,
            version: detail.version,
          ),
          WorkspaceRejected(:final failure) => throw failure,
        };
      },
    );
    if (mounted && receipt != null) _finish(receipt);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog, c = UiPalette.of(context);
    return PopScope(
      canPop: !_dirty && !_locked,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_locked) setState(() => _discard = true);
      },
      child: DesktopDialog(
        title: Text(_detail == null ? '添加${_type.name}' : '编辑${_type.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopTextField(
              key: const ValueKey('library-edit-name'),
              controller: _name,
              enabled: !_locked,
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
              enabled: !_locked,
              onChanged: _changed,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: '用途说明',
                errorText: _failure?.fieldErrors['description'],
              ),
            ),
            const SizedBox(height: 18),
            LibraryDirectorySelect(
              catalog: catalog,
              value: _directory,
              onChanged: _locked
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
                    onPressed: _locked
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
            for (final field in _definition['fields'] as List? ?? [])
              if (field['type'] == 'file') ...[
                const SizedBox(height: 18),
                if (_detail == null)
                  DesktopButton(
                    key: ValueKey('legacy-file-${field['key']}'),
                    onPressed: _locked || widget.filePicker == null
                        ? null
                        : () async {
                            setState(() => _pickingFile = true);
                            try {
                              final selection = await widget.filePicker!();
                              if (mounted && selection != null) {
                                _fileSelections[field['key'] as String] =
                                    selection;
                                _dirty = true;
                                _mutation.edited();
                              }
                            } on WorkspaceFailure catch (e) {
                              if (mounted) setState(() => _notice = e.message);
                            } catch (_) {
                              if (mounted) {
                                setState(() => _notice = '文件选择暂不可用，请重试。');
                              }
                            } finally {
                              if (mounted) setState(() => _pickingFile = false);
                            }
                          },
                    child: Text(
                      '${field['label']} · ${_fileSelections[field['key']]?.filename ?? '选择普通附件'}',
                    ),
                  )
                else
                  Text(
                    '文件内容通过详情中的“替换文件”入口更新。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
              ] else if (_entries[field['key']] case final entries?) ...[
                const SizedBox(height: 18),
                LibraryEntriesEditor(
                  key: ValueKey('library-entries-${field['key']}'),
                  fieldKey: field['key'] as String,
                  label: field['label'] as String,
                  entries: entries,
                  enabled: !_locked,
                  canAdd:
                      _readOnlyEntries.isEmpty &&
                      entries.length <
                          WorkspaceRepeatedEntry.maxEntriesPerField &&
                      _fields.length +
                              (_entries.values.fold<int>(
                                    0,
                                    (sum, list) =>
                                        sum +
                                        list.fold<int>(
                                          0,
                                          (n, entry) =>
                                              n + entry.fieldIds.length,
                                        ),
                                  ) +
                                  3) <=
                          WorkspaceRepeatedEntry.maxLeavesPerRecord,
                  errors: _failure?.fieldErrors ?? const {},
                  onChanged: (value) => setState(() {
                    _entries[field['key'] as String] = value;
                    _dirty = true;
                  }),
                ),
              ] else if (_readOnlyEntries.containsKey(field['key'])) ...[
                const SizedBox(height: 18),
                Text(
                  field['label'] as String,
                  style: libraryText(context, 13, weight: FontWeight.w600),
                ),
                Text(
                  '这些经历暂不能编辑，原有内容会保留。',
                  style: libraryText(context, 13, color: c.warning),
                ),
                LibraryEntryTimeline(_readOnlyEntries[field['key']]),
              ] else if (_documentFormats.contains(field['key'])) ...[
                const SizedBox(height: 18),
                DesktopSelect<String>(
                  key: ValueKey('library-edit-${field['key']}'),
                  value: _fields[field['key']]!.text,
                  items: [
                    for (final format in workspaceDocumentFormats.entries)
                      DropdownMenuItem(
                        value: format.key,
                        child: Text(format.value),
                      ),
                  ],
                  decoration: InputDecoration(
                    labelText: field['label'] as String,
                    errorText:
                        _failure?.fieldErrors[workspaceValueErrorKey(
                          field['key'] as String,
                        )],
                  ),
                  onChanged: _locked
                      ? null
                      : (value) => setState(() {
                          _fields[field['key']]!.text = value!;
                          _dirty = true;
                        }),
                ),
              ] else if (_fields.containsKey(field['key'])) ...[
                const SizedBox(height: 18),
                DesktopTextField(
                  key: ValueKey(
                    'library-edit-${['name', 'description'].contains(field['key']) ? 'value-' : ''}${field['key']}',
                  ),
                  controller: _fields[field['key']],
                  enabled: !_locked,
                  onChanged: _changed,
                  minLines: field['type'] == 'multiline' ? 3 : 1,
                  maxLines: field['type'] == 'multiline' ? 6 : 1,
                  decoration: InputDecoration(
                    labelText:
                        '${field['label']}${field['required'] == true ? ' *' : ''}',
                    errorText:
                        _failure?.fieldErrors[workspaceValueErrorKey(
                          field['key'] as String,
                        )],
                  ),
                ),
              ],
            for (final rule in _definition['relations'] as List? ?? []) ...[
              const SizedBox(height: 24),
              LibraryRelationPicker(
                key: ValueKey('library-relation-picker-${rule['key']}'),
                source: widget.controller.source,
                typeId: _type.id,
                record: _detail?.record.ref,
                relationKey: rule['key'] as String,
                label: rule['label'] as String,
                selected: _relations[rule['key']]!,
                enabled: !_locked,
                errorText: _failure?.fieldErrors['relation:${rule['key']}'],
                onChanged: (refs) => setState(() {
                  final key = rule['key'] as String;
                  _relations[key] = List.unmodifiable(refs);
                  _editedRelations.add(key);
                  _dirty = true;
                }),
              ),
            ],
          ],
        ),
        actions: [
          if (_notice != null)
            SizedBox(
              width: double.infinity,
              child: Semantics(liveRegion: true, child: Text(_notice!)),
            ),
          if (_failure?.code == 'conflict')
            DesktopButton(
              key: const ValueKey('library-edit-review-current'),
              busy: _reviewing,
              onPressed: _locked ? null : _reviewConflict,
              child: const Text('读取当前版本并核对'),
            ),
          if (_mutation.uncertain)
            DesktopButton(
              key: const ValueKey('library-edit-reconcile'),
              onPressed: _saving ? null : _reconcile,
              child: const Text('核对结果'),
            ),
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
              onPressed: _locked
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
            onPressed: _locked
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
            onPressed: _mutation.canSubmit && !_locked ? _save : null,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
