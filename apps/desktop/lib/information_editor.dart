import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

/// A UI draft, with no owner/proposal side effects. A changed name/kind is a
/// semantic replacement; public description and ordinary value edits retain ID.
class EditableInformationField {
  EditableInformationField({
    this.original,
    String? name,
    String? description,
    String? value,
    FieldKind? kind,
  }) : name = name ?? original?.name ?? '',
       description = description ?? original?.description ?? '',
       value = value ?? original?.value ?? '',
       kind = kind ?? original?.kind ?? FieldKind.structured;
  final InformationField? original;
  String name, description, value;
  FieldKind kind;
  bool get replacesIdentity =>
      original != null &&
      (name.trim() != original!.name || kind != original!.kind);
  FieldInput get input => FieldInput(name, description, value, kind: kind);
}

class InformationEditorDraft {
  InformationEditorDraft({
    this.original,
    String? name,
    String? description,
    String? directoryId,
    Iterable<String>? tagIds,
    List<EditableInformationField>? fields,
  }) : name = name ?? original?.name ?? '',
       description = description ?? original?.description ?? '',
       directoryId = directoryId ?? original?.directoryId,
       tagIds = {...?tagIds ?? original?.tagIds},
       fields =
           fields ??
           (original?.fields
                   .map((f) => EditableInformationField(original: f))
                   .toList() ??
               [EditableInformationField()]);
  final InformationItem? original;
  String name, description;
  String? directoryId;
  final Set<String> tagIds;
  final List<EditableInformationField> fields;
  List<FieldChange> get changes => [
    for (final old in original?.fields ?? <InformationField>[])
      if (!fields.any((f) => f.original?.id == old.id))
        FieldChange.remove(old.id),
    for (final field in fields)
      if (field.original == null)
        FieldChange.add(field.input)
      else if (field.replacesIdentity)
        FieldChange.replace(field.original!.id, field.input)
      else if (field.value != field.original!.value)
        FieldChange.correct(field.original!.id, field.value),
  ];
  Map<String, String> get fieldDescriptions => {
    for (final f in fields)
      if (f.original != null &&
          !f.replacesIdentity &&
          f.description != f.original!.description)
        f.original!.id: f.description,
  };
  void applyTemplate(InformationTemplate template) {
    name = name.isEmpty ? template.name : name;
    description = template.description;
    fields
      ..clear()
      ..addAll(
        template.fields.map(
          (f) => EditableInformationField(
            name: f.name,
            description: f.description,
            kind: f.kind,
          ),
        ),
      );
  }
}

typedef SaveInformationDraft =
    Future<void> Function(InformationEditorDraft draft);

class InformationEditor extends StatefulWidget {
  const InformationEditor({
    super.key,
    required this.draft,
    required this.onSave,
    this.directories = const [],
    this.tags = const [],
    this.templates = const [],
    this.title,
    this.saveLabel = '保存信息',
  });
  final InformationEditorDraft draft;
  final SaveInformationDraft onSave;
  final List<InformationDirectory> directories;
  final List<InformationTag> tags;
  final List<InformationTemplate> templates;
  final String? title;
  final String saveLabel;
  @override
  State<InformationEditor> createState() => _InformationEditorState();
}

class _InformationEditorState extends State<InformationEditor> {
  bool _dirty = false, _saving = false, _leaving = false;
  String? _error;
  int _templateRevision = 0;
  InformationEditorDraft get d => widget.draft;
  void _changed(VoidCallback change) => setState(() {
    change();
    _dirty = true;
  });
  Future<void> _close() async {
    if (_saving || _leaving) return;
    if (_dirty) {
      _leaving = true;
      final discard = await prototypeConfirm(
        context,
        title: '放弃未保存的更改？',
        message: '更改尚未保存。取消会继续保留当前输入，放弃后返回信息库。',
        action: '放弃更改',
      );
      _leaving = false;
      if (!discard || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (d.name.trim().isEmpty ||
        (d.original == null && d.fields.isEmpty) ||
        d.fields.any((f) => f.name.trim().isEmpty)) {
      setState(() => _error = '请填写信息名称和每个字段的名称。');
      return;
    }
    final destructive = d.changes
        .where(
          (c) =>
              c.kind == FieldChangeKind.remove ||
              c.kind == FieldChangeKind.replace,
        )
        .length;
    if (destructive > 0 &&
        !await prototypeConfirm(
          context,
          title: '确认字段身份变化',
          message:
              '$destructive 个字段将删除或被新含义替换。旧字段进入回收站，新增或恢复的字段需要重新授权；现有授权不会自动扩大。',
          action: '确认保存',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(d);
      if (mounted) Navigator.pop(context, true);
    } on AccessFailure catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.status == 'information_conflict'
              ? '当前信息已变化。输入已保留，请取消后重新打开并核对版本。'
              : '保存失败，信息库未改变。输入已保留，请重试。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，信息库未改变。输入已保留，请重试。';
        });
      }
    }
  }

  Widget _input(
    String label,
    String value,
    ValueChanged<String> update, {
    Key? key,
    int lines = 1,
    int max = 200,
  }) => Padding(
    padding: EdgeInsets.only(top: 10, bottom: lines == 1 ? 10 : 4.5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
          child: Text(label, style: prototypeText(context, 13)),
        ),
        const SizedBox(height: 7),
        SizedBox(
          height: 19.5 * lines * MediaQuery.textScalerOf(context).scale(1) + 20,
          child: TextFormField(
            key: key,
            initialValue: value,
            enabled: !_saving,
            maxLength: max,
            minLines: lines,
            maxLines: lines == 1 ? 1 : 6,
            onChanged: (v) => _changed(() => update(v)),
            style: prototypeText(context, 13),
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    null,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 10,
              ),
              filled: true,
              fillColor: UiPalette.of(context).paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _select<T>(
    String label,
    T? value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> change, {
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
          child: Text(label, style: prototypeText(context, 13)),
        ),
        const SizedBox(height: 7),
        SizedBox(
          height: 19.5 * MediaQuery.textScalerOf(context).scale(1) + 20,
          child: DropdownButtonFormField<T>(
            key: key,
            initialValue: value,
            items: items,
            isExpanded: true,
            style: prototypeText(context, 13),
            icon: const SizedBox.shrink(),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 9,
              ),
              filled: true,
              fillColor: UiPalette.of(context).paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
            onChanged: _saving ? null : (v) => _changed(() => change(v)),
          ),
        ),
      ],
    ),
  );
  String _path(String id) {
    final names = <String>[], seen = <String>{};
    String? cursor = id;
    while (cursor != null && seen.add(cursor)) {
      final f = widget.directories.where((d) => d.id == cursor).firstOrNull;
      if (f == null) break;
      names.insert(0, f.name);
      cursor = f.parentId;
    }
    return names.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final p = UiPalette.of(context);
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: PrototypeDialog(
        flow: true,
        title: widget.title ?? (d.original == null ? '新建信息' : '编辑信息'),
        onClose: _saving ? null : _close,
        body: Column(
          key: ValueKey(_templateRevision),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (d.original == null && widget.templates.isNotEmpty)
              _select<String>(
                '套用模板',
                null,
                [
                  const DropdownMenuItem(value: null, child: Text('手动新建')),
                  for (final template in widget.templates)
                    DropdownMenuItem(
                      value: template.id,
                      child: Text(template.name),
                    ),
                ],
                (id) {
                  if (id != null) {
                    d.applyTemplate(
                      widget.templates.firstWhere((t) => t.id == id),
                    );
                    _templateRevision++;
                  }
                },
                key: const ValueKey('new-template'),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _input(
                    '信息名称',
                    d.name,
                    (v) => d.name = v,
                    key: const ValueKey('item-name'),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _select<String>(
                    '所在目录',
                    d.directoryId,
                    [
                      const DropdownMenuItem(value: null, child: Text('未分类')),
                      for (final directory in widget.directories)
                        DropdownMenuItem(
                          value: directory.id,
                          child: Text(
                            _path(directory.id),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    (v) => d.directoryId = v,
                    key: const ValueKey('item-directory'),
                  ),
                ),
              ],
            ),
            _input(
              '公开说明',
              d.description,
              (v) => d.description = v,
              key: const ValueKey('item-description'),
              lines: 2,
              max: 2000,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
                    child: Text('标签', style: prototypeText(context, 13)),
                  ),
                  const SizedBox(height: 7),
                  TextButton(
                    key: const ValueKey('item-tags'),
                    onPressed: _saving ? null : _chooseTags,
                    style: prototypeButton(
                      context,
                      size: 13,
                      padding: const EdgeInsets.all(9),
                      foreground: p.ink,
                      side: BorderSide(color: p.line),
                    ),
                    child: SizedBox(
                      height:
                          19.5 * MediaQuery.textScalerOf(context).scale(1) + 2,
                      width: double.infinity,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.tags
                              .where((tag) => d.tagIds.contains(tag.id))
                              .map((tag) => tag.name)
                              .join('、'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '信息字段',
                style: prototypeText(context, 16, weight: FontWeight.w600),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: prototypeCh(context, 13, 48),
                ),
                child: Text(
                  '字段内容会按读取授权返回给 Agent。Token 和密钥请单独保存为凭据并建立关联。',
                  style: prototypeText(
                    context,
                    13,
                    height: 1.85,
                    color: p.muted,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10.3),
            for (var i = 0; i < d.fields.length; i++) _field(i),
            Wrap(
              spacing: 12,
              children: [
                TextButton(
                  key: const ValueKey('add-field'),
                  style: prototypeSecondary(context),
                  onPressed: _saving
                      ? null
                      : () => _changed(
                          () => d.fields.add(EditableInformationField()),
                        ),
                  child: const Text('添加字段'),
                ),
                TextButton(
                  key: const ValueKey('add-text-note'),
                  style: prototypeSecondary(context),
                  onPressed: _saving
                      ? null
                      : () => _changed(
                          () => d.fields.add(
                            EditableInformationField(
                              kind: FieldKind.textNote,
                              name: '文本说明',
                            ),
                          ),
                        ),
                  child: const Text('添加受控文本说明'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierColor: const Color(0x4f241b27),
                builder: (_) => PrototypeDialog(
                  title: 'Agent 可见的公开目录',
                  onClose: () => Navigator.pop(context),
                  body: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        d.name,
                        style: prototypeText(
                          context,
                          16,
                          weight: FontWeight.w600,
                        ),
                      ),
                      Text(d.description),
                      for (final f in d.fields)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text('${f.name}\n${f.description}'),
                        ),
                    ],
                  ),
                ),
              ),
              style: prototypeButton(context, size: 12, foreground: p.accent),
              child: const Text('预览公开目录'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: prototypeText(context, 13, color: p.danger),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            style: prototypeSecondary(context),
            onPressed: _saving ? null : _close,
            child: const Text('取消'),
          ),
          TextButton(
            style: prototypePrimary(context),
            key: const ValueKey('save-information'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const Text('正在保存…')
                : widget.saveLabel == '保存信息'
                ? const SizedBox(
                    width: 70,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [Text('保存'), Text('信息')],
                    ),
                  )
                : Text(widget.saveLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseTags() async {
    final selected = d.tagIds.toSet();
    final applied = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PrototypeDialog(
          title: '选择标签',
          onClose: () => Navigator.pop(dialogContext, false),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.tags.isEmpty) const Text('暂无标签，请先在目录与标签中创建。'),
              for (final tag in widget.tags)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      PrototypeCheck(
                        value: selected.contains(tag.id),
                        onChanged: (v) => update(
                          () => v == true
                              ? selected.add(tag.id)
                              : selected.remove(tag.id),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        style: prototypeButton(context, size: 13),
                        onPressed: () => update(
                          () => selected.contains(tag.id)
                              ? selected.remove(tag.id)
                              : selected.add(tag.id),
                        ),
                        child: Text(tag.name),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              style: prototypePrimary(context),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('使用所选标签'),
            ),
          ],
        ),
      ),
    );
    if (applied == true && mounted) {
      _changed(() {
        d.tagIds
          ..clear()
          ..addAll(selected);
      });
    }
  }

  Widget _field(int index) {
    final f = d.fields[index], p = UiPalette.of(context);
    return Container(
      key: ObjectKey(f),
      padding: const EdgeInsets.only(top: 13, bottom: 13),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _input(
                  '字段名称',
                  f.name,
                  (v) => f.name = v,
                  key: ValueKey('field-name-$index'),
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                flex: 2,
                child: _input(
                  f.kind == FieldKind.textNote ? '受控文本说明' : '字段内容',
                  f.value,
                  (v) => f.value = v,
                  key: ValueKey('field-value-$index'),
                  lines: f.kind == FieldKind.textNote ? 3 : 1,
                  max: 64000,
                ),
              ),
            ],
          ),
          _input(
            '字段公开说明',
            f.description,
            (v) => f.description = v,
            key: ValueKey('field-description-$index'),
            max: 2000,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: prototypeButton(
                context,
                size: 13,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                foreground: p.accent,
              ),
              onPressed: _saving
                  ? null
                  : () => _changed(() => d.fields.removeAt(index)),
              child: const Text('移除字段'),
            ),
          ),
          if (f.replacesIdentity)
            Text(
              '名称或种类变化将创建新字段身份，需要重新授权。',
              style: prototypeText(context, 12, color: p.accent),
            ),
        ],
      ),
    );
  }
}
