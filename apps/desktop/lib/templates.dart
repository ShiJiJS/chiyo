import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

class TemplateLibrary extends StatefulWidget {
  const TemplateLibrary({
    super.key,
    required this.owner,
    this.backLabel = '设置',
  });
  final OwnerAccess owner;
  final String backLabel;
  @override
  State<TemplateLibrary> createState() => _TemplateLibraryState();
}

class _TemplateLibraryState extends State<TemplateLibrary> {
  Future<void> _edit([InformationTemplate? template]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TemplateEditor(owner: widget.owner, template: template),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => DesktopSubpage(
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
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => _TemplateInformation(
                        owner: widget.owner,
                        template: template,
                      ),
                    ),
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
                              style: Theme.of(context).textTheme.bodySmall,
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

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text(widget.template == null ? '新建模板' : '修改模板'),
    content: SizedBox(
      width: 860,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const QuietNotice('保存模板不会修改已有信息或授权。修改字段含义或类型会生成新的字段定义；已有信息保留原值。'),
            const SizedBox(height: 16),
            EditorColumns(
              metadata: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DesktopTextField(
                    key: const ValueKey('template-name'),
                    controller: _name,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: '模板名称'),
                  ),
                  DesktopTextField(
                    controller: _description,
                    maxLength: 2000,
                    decoration: const InputDecoration(labelText: '模板说明'),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: SectionHeading('字段定义', detail: '名称和说明公开'),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _saving || _fields.length >= 200
                              ? null
                              : () => setState(
                                  () => _fields.add(_DefinitionControllers()),
                                ),
                          child: const Text('添加字段定义'),
                        ),
                      ),
                    ],
                  ),
                  for (var i = 0; i < _fields.length; i++)
                    Padding(
                      key: ObjectKey(_fields[i]),
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (i > 0)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Divider(),
                            ),
                          SectionHeading('字段 ${i + 1}'),
                          DesktopTextField(
                            key: ValueKey('template-field-name-$i'),
                            controller: _fields[i].name,
                            maxLength: 200,
                            decoration: const InputDecoration(
                              labelText: '字段名称（公开）',
                            ),
                          ),
                          DesktopTextField(
                            controller: _fields[i].description,
                            maxLength: 2000,
                            decoration: const InputDecoration(
                              labelText: '字段说明（公开）',
                            ),
                          ),
                          DesktopSelect<FieldKind>(
                            initialValue: _fields[i].kind,
                            decoration: const InputDecoration(
                              labelText: '内容形式',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: FieldKind.structured,
                                child: Text('结构化字段'),
                              ),
                              DropdownMenuItem(
                                value: FieldKind.textNote,
                                child: Text('文本说明'),
                              ),
                            ],
                            onChanged: _saving
                                ? null
                                : (value) =>
                                      setState(() => _fields[i].kind = value!),
                          ),
                          if (_fields.length > 1)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: _saving || _fields.length == 1
                                    ? null
                                    : () => setState(
                                        () => _removed.add(_fields.removeAt(i)),
                                      ),
                                child: const Text('移除此字段定义'),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (_error != null) QuietNotice(_error!, warning: true),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('保存模板'),
      ),
    ],
  );
}

class _TemplateInformation extends StatefulWidget {
  const _TemplateInformation({required this.owner, required this.template});
  final OwnerAccess owner;
  final InformationTemplate template;
  @override
  State<_TemplateInformation> createState() => _TemplateInformationState();
}

class _TemplateInformationState extends State<_TemplateInformation> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  late final _values = {
    for (final f in widget.template.fields) f.id: TextEditingController(),
  };
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final value in _values.values) {
      value.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.owner.createInformationFromTemplate(
        widget.template.id,
        widget.template.version,
        _name.text,
        _description.text,
        _values.map((id, value) => MapEntry(id, value.text)),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is AccessFailure && error.status == 'template_changed'
              ? '模板已更新。当前草稿尚未保存，请复制需保留的内容，取消后重新使用模板。'
              : '保存失败，请填写信息名称并检查存储状态。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text('使用模板：${widget.template.name}'),
    content: SizedBox(
      width: 860,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const QuietNotice('只有点击“保存信息”才会写入资料库；新信息需要另行申请授权。'),
            const SizedBox(height: 16),
            EditorColumns(
              metadata: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeading('公开目录', detail: 'Agent 可见'),
                  DesktopTextField(
                    key: const ValueKey('template-item-name'),
                    controller: _name,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: '信息名称（公开）'),
                  ),
                  DesktopTextField(
                    controller: _description,
                    maxLength: 2000,
                    decoration: const InputDecoration(labelText: '公开描述'),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeading('信息字段', detail: '按字段授权'),
                  for (var i = 0; i < widget.template.fields.length; i++) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Divider(),
                    ),
                    Text('${widget.template.fields[i].name}（公开）'),
                    Text(widget.template.fields[i].description),
                    DesktopTextField(
                      key: ValueKey('template-value-$i'),
                      controller: _values[widget.template.fields[i].id],
                      minLines:
                          widget.template.fields[i].kind == FieldKind.textNote
                          ? 3
                          : 1,
                      maxLines:
                          widget.template.fields[i].kind == FieldKind.textNote
                          ? 10
                          : 4,
                      maxLength: 1000000,
                      decoration: InputDecoration(
                        labelText:
                            widget.template.fields[i].kind == FieldKind.textNote
                            ? '文本说明（需要授权）'
                            : '字段值（需要授权）',
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (_error != null) QuietNotice(_error!, warning: true),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('保存信息'),
      ),
    ],
  );
}
