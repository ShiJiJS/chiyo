import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'templates.dart';
import 'recycle.dart';
import 'revisions.dart';
import 'ui.dart';

class InformationLibrary extends StatefulWidget {
  const InformationLibrary({super.key, required this.owner, this.refresh});
  final OwnerAccess owner;
  final Listenable? refresh;
  @override
  State<InformationLibrary> createState() => _InformationLibraryState();
}

class _InformationLibraryState extends State<InformationLibrary> {
  Listenable? _refresh;
  void _refreshInformation() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindRefresh();
  }

  @override
  void didUpdateWidget(covariant InformationLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindRefresh();
  }

  void _bindRefresh() {
    final next = widget.refresh ?? DefaultTabController.maybeOf(context);
    if (identical(next, _refresh)) return;
    _refresh?.removeListener(_refreshInformation);
    _refresh = next;
    _refresh?.addListener(_refreshInformation);
  }

  @override
  void dispose() {
    _refresh?.removeListener(_refreshInformation);
    super.dispose();
  }

  String? _directoryFilter;
  String? _tagFilter;
  List<InformationItem> get _visibleInformation {
    final ids = _directoryFilter == null
        ? null
        : widget.owner
              .fieldsInDirectory(_directoryFilter!)
              .map((f) => f.itemId)
              .toSet();
    return widget.owner.information
        .where(
          (item) =>
              (ids == null || ids.contains(item.id)) &&
              (_tagFilter == null || item.tagIds.contains(_tagFilter)),
        )
        .toList();
  }

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
    body: Padding(
      padding: const EdgeInsets.fromLTRB(26, 25, 26, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(
            '资料库',
            subtitle:
          '${widget.owner.information.length} 条信息 · 字段值按授权范围提供给 Agent',
            actions: [
              TextButton(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RecyclePage(owner: widget.owner),
                    ),
                  );
                  if (mounted) setState(() {});
                },
                child: const Text('回收站'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await manageOrganization(context, widget.owner);
                  if (mounted) setState(() {});
                },
                child: const Text('目录与标签'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TemplateLibrary(owner: widget.owner),
                    ),
                  );
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.view_list_outlined, size: 17),
                label: const Text('字段模板'),
              ),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建信息'),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              children: [
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<String>(
                      key: const ValueKey('browse-directory'),
                      value: _directoryFilter,
                      hint: const Text('全部目录'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('全部目录'),
                        ),
                        for (final directory in widget.owner.directories)
                          DropdownMenuItem(
                            value: directory.id,
                            child: Text(
                              directoryPath(widget.owner, directory.id),
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _directoryFilter = value),
                    ),
                    DropdownButton<String>(
                      key: const ValueKey('browse-tag'),
                      value: _tagFilter,
                      hint: const Text('全部标签'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('全部标签'),
                        ),
                        for (final tag in widget.owner.tags)
                          DropdownMenuItem(
                            value: tag.id,
                            child: Text(tag.name),
                          ),
                      ],
                      onChanged: (value) => setState(() => _tagFilter = value),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const QuietNotice('名称、公开描述和字段说明会出现在 Agent 目录中，请勿在这些位置填写秘密。'),
                const SizedBox(height: 12),
                if (widget.owner.information.isEmpty)
                  const SizedBox(
                    height: 320,
                    child: EmptyWorkspace(
                      icon: Icons.folder_open_outlined,
                      title: '还没有信息，可以手动新建。',
                      description: '也可以让 Agent 整理资料并提交录入提案，由你预览后确认入库。',
                    ),
                  ),
                if (widget.owner.information.isNotEmpty &&
                    _visibleInformation.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(28),
                    child: Text('当前目录和标签下没有信息。'),
                  ),
                if (_visibleInformation.isNotEmpty)
                  Material(
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                      side: const BorderSide(color: UiColors.line),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (
                          var i = 0;
                          i < _visibleInformation.length;
                          i++
                        ) ...[
                          if (i > 0) const Divider(),
                          _informationRow(_visibleInformation[i]),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _informationRow(InformationItem item) => ExpansionTile(
    key: ValueKey(item.id),
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    expandedAlignment: Alignment.centerLeft,
    tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
    leading: const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Icon(Icons.description_outlined, size: 21, color: UiColors.muted),
    ),
    title: Text(item.name, style: Theme.of(context).textTheme.titleMedium),
    subtitle: Text(
      item.description,
      style: Theme.of(context).textTheme.bodySmall,
    ),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  directoryPath(widget.owner, item.directoryId),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final tag in widget.owner.tags.where(
                  (t) => item.tagIds.contains(t.id),
                ))
                  Text(
                    '· ${tag.name}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await editCatalogMetadata(context, widget.owner, item);
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('编辑公开说明'),
                ),
                TextButton(
                  onPressed: () async {
                    await organizeItem(context, widget.owner, item);
                    if (mounted) setState(() {});
                  },
                  child: const Text('整理位置和标签'),
                ),
                TextButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RevisionHistoryPage(
                          owner: widget.owner,
                          itemId: item.id,
                        ),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                  child: const Text('修改历史'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: UiColors.danger),
                  onPressed: () async {
                    await confirmInformationDeletion(
                      context,
                      widget.owner,
                      item,
                    );
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('删除整条信息'),
                ),
              ],
            ),
          ],
        ),
      ),
      const Divider(),
      for (final field in item.fields)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          title: Text(field.name, style: Theme.of(context).textTheme.bodySmall),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: SelectableText(
              field.value,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '修正值',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _correct(item, field),
              ),
              IconButton(
                tooltip: '删除字段',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () async {
                  await confirmInformationDeletion(
                    context,
                    widget.owner,
                    item,
                    fieldId: field.id,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
    ],
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
