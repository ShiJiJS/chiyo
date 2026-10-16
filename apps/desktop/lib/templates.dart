import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'information_editor.dart';

class TemplateLibrary extends StatefulWidget {
  const TemplateLibrary({
    super.key,
    required this.owner,
    this.backLabel = '设置',
    this.embedded = false,
  });
  final OwnerAccess owner;
  final String backLabel;
  final bool embedded;
  @override
  State<TemplateLibrary> createState() => _TemplateLibraryState();
}

class _TemplateLibraryState extends State<TemplateLibrary> {
  String? _selected;
  String? _error;
  Future<void> _delete(InformationTemplate template) async {
    final confirm = await showSettingsDialog<bool>(
      context: context,
      builder: (context) => SettingsDialog(
        title: '删除录入模板',
        actions: [
          settingsAction(context, '取消', () => Navigator.pop(context, false)),
          settingsAction(
            context,
            '删除模板',
            () => Navigator.pop(context, true),
            primary: true,
          ),
        ],
        child: Text('删除「${template.name}」的字段结构。已经创建的信息保持原有内容。'),
      ),
    );
    if (confirm != true) return;
    try {
      await widget.owner.deleteTemplate(template.id, template.version);
      if (mounted) {
        setState(() {
          _selected = null;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '模板未删除，请检查存储或重新打开模板后重试。');
    }
  }

  Widget _embedded() {
    final templates = widget.owner.templates;
    final selected =
        templates.where((t) => t.id == _selected).firstOrNull ??
        templates.firstOrNull;
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '我的模板',
                style: prototypeText(context, 16, weight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: () => _edit(),
              style: prototypeButton(
                context,
                size: 12,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                side: BorderSide(color: c.line),
                radius: 4,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const PrototypeIcon(PrototypeIconGlyph.plus),
                  const SizedBox(width: 7),
                  const Text('新建模板'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '模板只包含字段名称与结构，不保存任何字段值。',
          style: prototypeText(context, 13, color: c.muted, height: 1.9),
        ),
        const SizedBox(height: 30),
        if (selected == null) const Text('还没有录入模板。'),
        if (selected != null)
          Container(
            decoration: BoxDecoration(
              color: c.paper,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 200,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.rail,
                      border: Border(right: BorderSide(color: c.line)),
                    ),
                    child: Column(
                      children: [
                        for (final template in templates)
                          TextButton(
                            onPressed: () =>
                                setState(() => _selected = template.id),
                            style: prototypeButton(
                              context,
                              size: 13,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 14,
                              ),
                              background: selected.id == template.id
                                  ? c.selected
                                  : Colors.transparent,
                            ),
                            child: Row(
                              children: [
                                const PrototypeIcon(PrototypeIconGlyph.file),
                                const SizedBox(width: 9),
                                Expanded(child: Text(template.name)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 25,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            selected.name,
                            style: prototypeText(
                              context,
                              20,
                              family: 'SimSun',
                              weight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            selected.description.isEmpty
                                ? '新建信息时可直接套用这些空白字段。'
                                : selected.description,
                            style: prototypeText(context, 13, color: c.muted),
                          ),
                          const SizedBox(height: 17.5),
                          for (final (index, f) in selected.fields.indexed)
                            Container(
                              // Match CSS's alternating 50/51px row edges while
                              // allowing long field names to grow naturally.
                              padding: EdgeInsets.symmetric(
                                vertical: index == 0
                                    ? 14.75
                                    : index.isOdd
                                    ? 14.5
                                    : 15,
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: c.line),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      f.name,
                                      style: prototypeText(context, 13),
                                    ),
                                  ),
                                  Tooltip(
                                    message: f.description,
                                    child: Text(
                                      f.kind == FieldKind.textNote
                                          ? '多行文本'
                                          : '文本',
                                      style: prototypeText(
                                        context,
                                        12,
                                        color: c.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 20),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                settingsAction(
                                  context,
                                  '修改模板',
                                  () => _edit(selected),
                                ),
                                TextButton(
                                  style: prototypeButton(
                                    context,
                                    size: 13,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 10,
                                    ),
                                    foreground: c.strong,
                                  ),
                                  onPressed: () => _useTemplate(selected),
                                  child: const Text('使用模板 →'),
                                ),
                                settingsAction(
                                  context,
                                  '删除模板',
                                  () => _delete(selected),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_error != null) SettingsNotice('操作未完成', _error!, error: true),
      ],
    );
  }

  Future<void> _edit([InformationTemplate? template]) async {
    await showSettingsDialog<void>(
      context: context,
      builder: (_) => _TemplateEditor(owner: widget.owner, template: template),
    );
    if (mounted) setState(() {});
  }

  Future<void> _useTemplate(InformationTemplate template) async {
    final draft = InformationEditorDraft(
      fields: template.fields
          .map(
            (f) => EditableInformationField(
              name: f.name,
              description: f.description,
              kind: f.kind,
            ),
          )
          .toList(),
      description: template.description,
    );
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => InformationEditor(
        draft: draft,
        title: '使用模板：${template.name}',
        directories: widget.owner.directories,
        tags: widget.owner.tags,
        onSave: (d) async {
          await widget.owner.createInformation(
            d.name,
            d.description,
            d.fields.map((f) => f.input).toList(),
            directoryId: d.directoryId,
            tagIds: d.tagIds,
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _embedded()
      : DesktopSubpage(
          title: '录入模板',
          backLabel: widget.backLabel,
          actions: [
            TextButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('新建模板'),
            ),
          ],
          body: ReadingWorkspace(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  '录入模板是一套可重复使用的空白字段。例如“服务器”模板可以预设地址、用户名和部署说明，新建资料时再填写各自的值。模板不保存字段值，修改模板不会修改已有资料或授权。',
                ),
                if (widget.owner.templates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 24),
                    child: Text('还没有录入模板。'),
                  ),
                for (final template in widget.owner.templates) ...[
                  const SizedBox(height: 20),
                  WorkspaceRecord(
                    title: Text(
                      template.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    subtitle: Text(template.description),
                    trailing: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => _edit(template),
                          child: const Text('修改模板'),
                        ),
                        FilledButton(
                          onPressed: () => _useTemplate(template),
                          child: const Text('使用模板'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  SectionHeading(
                    '字段定义',
                    detail: '${template.fields.length} 个字段 · 不包含字段值',
                  ),
                  for (final field in template.fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: LayoutBuilder(
                        builder: (context, bounds) {
                          final kind = field.kind == FieldKind.textNote
                              ? '文本说明'
                              : '结构化字段';
                          if (bounds.maxWidth < 700 ||
                              MediaQuery.textScalerOf(context).scale(14) > 20) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${field.name} · $kind'),
                                if (field.description.isNotEmpty)
                                  Text(
                                    field.description,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: 200, child: Text(field.name)),
                              SizedBox(
                                width: 160,
                                child: Text(
                                  kind,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  field.description,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 18),
                ],
              ],
            ),
          ),
        );
}

class _DefinitionControllers {
  _DefinitionControllers([TemplateFieldDefinition? field])
    : id = field?.id,
      name = TextEditingController(text: field?.name),
      description = TextEditingController(text: field?.description),
      kind = field?.kind ?? FieldKind.structured;
  final String? id;
  final TextEditingController name, description;
  FieldKind kind;
  void dispose() {
    name.dispose();
    description.dispose();
  }
}

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({required this.owner, this.template});
  final OwnerAccess owner;
  final InformationTemplate? template;
  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final _name = TextEditingController(text: widget.template?.name);
  late final _description = TextEditingController(
    text: widget.template?.description,
  );
  late final List<_DefinitionControllers> _fields =
      widget.template?.fields.map(_DefinitionControllers.new).toList() ??
      [_DefinitionControllers()];
  final _removed = <_DefinitionControllers>[];
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final f in [..._fields, ..._removed]) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final fields = _fields
          .map(
            (f) => TemplateFieldInput(
              f.name.text,
              f.description.text,
              kind: f.kind,
              definitionId: f.id,
            ),
          )
          .toList();
      final template = widget.template;
      if (template == null) {
        await widget.owner.createTemplate(
          _name.text,
          _description.text,
          fields,
        );
      } else {
        await widget.owner.updateTemplate(
          template.id,
          template.version,
          _name.text,
          _description.text,
          fields,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is AccessFailure && error.status == 'template_changed'
              ? '模板已更新，请取消并重新打开后编辑。'
              : '保存失败，请填写模板和字段名称，并检查存储状态。';
        });
      }
    }
  }

  bool _showDescriptions = false;

  Widget _input(
    TextEditingController controller, {
    Key? key,
    String? hint,
    int maxLength = 200,
    double size = 14,
  }) => SizedBox(
    height: size * 1.5 * MediaQuery.textScalerOf(context).scale(1) + 24,
    child: TextField(
      key: key,
      controller: controller,
      maxLength: maxLength,
      buildCounter:
          (_, {required currentLength, required isFocused, maxLength}) => null,
      enabled: !_saving,
      textAlignVertical: TextAlignVertical.top,
      style: prototypeText(context, size),
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        isDense: true,
        filled: true,
        fillColor: UiPalette.of(context).rail,
        contentPadding: EdgeInsets.fromLTRB(
          9,
          size == 13 ? 12 : 11,
          9,
          size == 13 ? 12 : 13,
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: UiPalette.of(context).line),
          borderRadius: BorderRadius.circular(4),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: UiPalette.of(context).accent),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => SettingsDialog(
    title: '字段结构',
    busy: _saving,
    actions: [
      settingsAction(
        context,
        '取消',
        _saving ? null : () => Navigator.pop(context),
      ),
      settingsAction(context, '保存模板', _saving ? null : _save, primary: true),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '仅保存空白字段结构，不包含实际信息值。',
          style: prototypeText(
            context,
            14,
            color: UiPalette.of(context).muted,
            height: 1.85,
          ),
        ),
        const SizedBox(height: 20),
        Text('模板名称', style: prototypeText(context, 13)),
        const SizedBox(height: 7),
        _input(
          _name,
          key: const ValueKey('template-name'),
          hint: '例如：服务器',
          size: 13,
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < _fields.length; i++)
          Padding(
            key: ObjectKey(_fields[i]),
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: _input(
                    _fields[i].name,
                    key: ValueKey('template-field-name-$i'),
                    hint: '字段名称',
                  ),
                ),
                const SizedBox(width: 12),
                PopupMenuButton<FieldKind>(
                  tooltip: '字段形式',
                  enabled: !_saving,
                  initialValue: _fields[i].kind,
                  onSelected: (value) =>
                      setState(() => _fields[i].kind = value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: FieldKind.structured,
                      child: Text('文本'),
                    ),
                    PopupMenuItem(
                      value: FieldKind.textNote,
                      child: Text('多行文本'),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: UiPalette.of(context).line),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      _fields[i].kind == FieldKind.textNote ? '多行文本' : '文本',
                      style: prototypeText(
                        context,
                        11,
                        color: UiPalette.of(context).muted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox.square(
                  dimension: 26,
                  child: TextButton(
                    onPressed: _saving || _fields.length == 1
                        ? null
                        : () =>
                              setState(() => _removed.add(_fields.removeAt(i))),
                    style: prototypeButton(context, size: 20),
                    child: Transform.translate(
                      offset: const Offset(2.5, -3),
                      child: const Text('×', textScaler: TextScaler.noScaling),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            TextButton(
              onPressed: _saving || _fields.length >= 200
                  ? null
                  : () => setState(() => _fields.add(_DefinitionControllers())),
              style: prototypeButton(
                context,
                size: 13,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                foreground: UiPalette.of(context).accent,
              ),
              child: const Text('＋ 添加字段'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () =>
                  setState(() => _showDescriptions = !_showDescriptions),
              style: prototypeButton(
                context,
                size: 12,
                foreground: UiPalette.of(context).muted,
              ),
              child: Text(_showDescriptions ? '收起说明' : '编辑说明'),
            ),
          ],
        ),
        if (_showDescriptions) ...[
          const SizedBox(height: 12),
          Text(
            '保存模板不会修改已有信息或授权。说明公开可见，不应包含字段值。',
            style: prototypeText(
              context,
              12,
              color: UiPalette.of(context).muted,
              height: 1.8,
            ),
          ),
          const SizedBox(height: 10),
          Text('模板说明', style: prototypeText(context, 13)),
          _input(_description, maxLength: 2000),
          for (var i = 0; i < _fields.length; i++) ...[
            const SizedBox(height: 10),
            Text('字段 ${i + 1} 说明', style: prototypeText(context, 13)),
            _input(_fields[i].description, maxLength: 2000),
          ],
        ],
        if (_error != null) SettingsNotice('模板尚未保存', _error!, error: true),
      ],
    ),
  );
}
