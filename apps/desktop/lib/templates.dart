import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

class TemplateLibrary extends StatefulWidget {
  const TemplateLibrary({super.key, required this.owner});
  final OwnerAccess owner;
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('字段模板'),
      actions: [
        TextButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('新建模板'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '模板用于辅助录入。修改或扩展模板不会修改已有信息，也不会扩大已有授权。模板中的名称和说明将用作新信息的公开字段说明，请勿填写秘密。',
        ),
        if (widget.owner.templates.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('还没有字段模板。'),
          ),
        for (final template in widget.owner.templates)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    template.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(template.description),
                  Text(
                    template.fields
                        .map(
                          (f) =>
                              '${f.name}（${f.kind == FieldKind.textNote ? '文本说明' : '结构化字段'}）',
                        )
                        .join('、'),
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      TextButton(
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
                ],
              ),
            ),
          ),
      ],
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
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.template == null ? '新建模板' : '修改模板'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('保存模板不会修改已有信息或授权。修改字段含义或类型会生成新的字段定义；已有信息保留原值。'),
            TextField(
              key: const ValueKey('template-name'),
              controller: _name,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '模板名称'),
            ),
            TextField(
              controller: _description,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '模板说明'),
            ),
            for (var i = 0; i < _fields.length; i++)
              Padding(
                key: ObjectKey(_fields[i]),
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    const Divider(),
                    TextField(
                      key: ValueKey('template-field-name-$i'),
                      controller: _fields[i].name,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: '字段名称（公开）'),
                    ),
                    TextField(
                      controller: _fields[i].description,
                      maxLength: 2000,
                      decoration: const InputDecoration(labelText: '字段说明（公开）'),
                    ),
                    DropdownButtonFormField<FieldKind>(
                      initialValue: _fields[i].kind,
                      decoration: const InputDecoration(labelText: '内容形式'),
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
                          : (value) => setState(() => _fields[i].kind = value!),
                    ),
                    TextButton(
                      onPressed: _saving || _fields.length == 1
                          ? null
                          : () => setState(
                              () => _removed.add(_fields.removeAt(i)),
                            ),
                      child: const Text('移除此字段定义'),
                    ),
                  ],
                ),
              ),
            TextButton(
              onPressed: _saving || _fields.length >= 200
                  ? null
                  : () => setState(() => _fields.add(_DefinitionControllers())),
              child: const Text('添加字段定义'),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
  Widget build(BuildContext context) => AlertDialog(
    title: Text('使用模板：${widget.template.name}'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请检查公开说明和内容。只有点击“保存信息”才会写入资料库；新信息需要另行申请授权。'),
            TextField(
              key: const ValueKey('template-item-name'),
              controller: _name,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '信息名称（公开）'),
            ),
            TextField(
              controller: _description,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '公开描述'),
            ),
            for (var i = 0; i < widget.template.fields.length; i++) ...[
              const Divider(),
              Text('${widget.template.fields[i].name}（公开）'),
              Text(widget.template.fields[i].description),
              TextField(
                key: ValueKey('template-value-$i'),
                controller: _values[widget.template.fields[i].id],
                minLines: widget.template.fields[i].kind == FieldKind.textNote
                    ? 3
                    : 1,
                maxLines: widget.template.fields[i].kind == FieldKind.textNote
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
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
