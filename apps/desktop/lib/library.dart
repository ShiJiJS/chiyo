import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

class InformationLibrary extends StatefulWidget {
  const InformationLibrary({super.key, required this.owner});
  final OwnerAccess owner;
  @override
  State<InformationLibrary> createState() => _InformationLibraryState();
}

class _InformationLibraryState extends State<InformationLibrary> {
  Future<void> _create() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CreateInformation(owner: widget.owner),
    );
    if (mounted) setState(() {});
  }

  Future<void> _correct(InformationItem item, InformationField field) async {
    var editedValue = field.value;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('修正 ${field.name}'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('仅修正同一含义的值，已有授权会读取新值。若内容含义改变，请新建信息；新信息需要另行授权。'),
              TextFormField(
                initialValue: field.value,
                onChanged: (value) => editedValue = value,
                minLines: 2,
                maxLines: 8,
                maxLength: 1000000,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, editedValue),
            child: const Text('保存修正'),
          ),
        ],
      ),
    );
    if (value != null) {
      try {
        await widget.owner.correctValue(FieldRef(item.id, field.id), value);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('保存失败，资料未更新。')));
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('我的信息'),
      actions: [
        TextButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add),
          label: const Text('新建信息'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '当前为开发版本，恢复链路尚未验收，请只使用虚构资料。名称、公开描述和字段说明会出现在 Agent 目录中，请勿在这些位置填写秘密。',
        ),
        const SizedBox(height: 20),
        if (widget.owner.information.isEmpty) const Text('还没有信息，可以手动新建。'),
        for (final item in widget.owner.information)
          Card(
            child: ExpansionTile(
              title: Text(item.name),
              subtitle: Text(item.description),
              children: [
                for (final field in item.fields)
                  ListTile(
                    title: Text(field.name),
                    subtitle: SelectableText(field.value),
                    trailing: IconButton(
                      tooltip: '修正值',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _correct(item, field),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _FieldControllers {
  final name = TextEditingController();
  final description = TextEditingController();
  final value = TextEditingController();
  void dispose() {
    name.dispose();
    description.dispose();
    value.dispose();
  }
}

class _CreateInformation extends StatefulWidget {
  const _CreateInformation({required this.owner});
  final OwnerAccess owner;
  @override
  State<_CreateInformation> createState() => _CreateInformationState();
}

class _CreateInformationState extends State<_CreateInformation> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _fields = [_FieldControllers()];
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.owner.createInformation(
        _name.text,
        _description.text,
        _fields
            .map(
              (f) => FieldInput(f.name.text, f.description.text, f.value.text),
            )
            .toList(),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败。请填写信息名称和字段名称，并检查存储状态。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建信息'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('item-name'),
              controller: _name,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '信息名称（公开）'),
            ),
            TextField(
              controller: _description,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '公开描述'),
            ),
            for (var i = 0; i < _fields.length; i++) ...[
              const Divider(),
              TextField(
                key: ValueKey('field-name-$i'),
                controller: _fields[i].name,
                maxLength: 200,
                decoration: const InputDecoration(labelText: '字段名称（公开）'),
              ),
              TextField(
                controller: _fields[i].description,
                maxLength: 2000,
                decoration: const InputDecoration(labelText: '字段说明（公开）'),
              ),
              TextField(
                key: ValueKey('field-value-$i'),
                controller: _fields[i].value,
                minLines: 1,
                maxLines: 6,
                maxLength: 1000000,
                decoration: const InputDecoration(labelText: '字段值或文本说明（需要授权）'),
              ),
            ],
            TextButton(
              onPressed: _saving || _fields.length >= 200
                  ? null
                  : () => setState(() => _fields.add(_FieldControllers())),
              child: const Text('添加字段'),
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
        child: const Text('保存信息'),
      ),
    ],
  );
}
