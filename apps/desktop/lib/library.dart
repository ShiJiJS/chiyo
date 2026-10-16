import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
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

  final _expandedDescriptions = <String>{};
  String? _selectedId;
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
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _CorrectValue(owner: widget.owner, item: item, field: field),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: UiSpace.page,
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
              FilledButton.icon(
                onPressed: _create,
                icon: Icon(Icons.add, size: 18),
                label: const Text('新建信息'),
              ),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DesktopSelect<String>(
                key: const ValueKey('browse-directory'),
                value: _directoryFilter,
                hint: const Text('全部目录'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('全部目录')),
                  for (final d in widget.owner.directories)
                    DropdownMenuItem(
                      value: d.id,
                      child: Text(directoryPath(widget.owner, d.id)),
                    ),
                ],
                onChanged: (value) => setState(() => _directoryFilter = value),
              ),
              DesktopSelect<String>(
                key: const ValueKey('browse-tag'),
                value: _tagFilter,
                hint: const Text('全部标签'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('全部标签')),
                  for (final t in widget.owner.tags)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (value) => setState(() => _tagFilter = value),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const QuietNotice('名称、公开描述和字段说明会出现在 Agent 目录中，请勿在这些位置填写秘密。'),
          const SizedBox(height: 12),
          Expanded(child: _workspace()),
        ],
      ),
    ),
  );

  Widget _workspace() {
    final items = _visibleInformation;
    if (items.isEmpty) {
      return EmptyWorkspace(
        icon: Icons.folder_open_outlined,
        title: widget.owner.information.isEmpty
            ? '还没有信息，可以手动新建。'
            : '当前目录和标签下没有信息。',
        description: '也可以让 Agent 整理资料并提交录入提案，由你预览后确认入库。',
      );
    }
    final current =
        items.where((i) => i.id == _selectedId).firstOrNull ?? items.first;
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth >= 900;
        final index = ListView(
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color: item.id == current.id
                      ? UiPalette.of(context).selected
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    key: ValueKey(item.id),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(() => _selectedId = item.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 15,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${item.fields.length} 个字段 · ${directoryPath(widget.owner, item.directoryId)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
        final document = ListView(
          key: ValueKey('information-${current.id}'),
          padding: EdgeInsets.only(left: wide ? 28 : 0, top: wide ? 0 : 18),
          children: [_informationDocument(current)],
        );
        if (!wide) {
          return Column(
            children: [
              SizedBox(height: 150, child: index),
              const Divider(),
              Expanded(child: document),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 300, child: index),
            const SizedBox(width: 20),
            const VerticalDivider(width: 1),
            Expanded(child: document),
          ],
        );
      },
    );
  }

  Widget _informationDocument(InformationItem item) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              item.name,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ),
          TextButton.icon(
            key: const ValueKey('edit-information-description'),
            onPressed: () async {
              await editCatalogMetadata(context, widget.owner, item);
              if (mounted) setState(() {});
            },
            icon: Icon(Icons.edit_outlined, size: 16),
            label: const Text('编辑'),
          ),
          IconButton(
            tooltip: '历史',
            icon: Icon(Icons.history_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      RevisionHistoryPage(owner: widget.owner, itemId: item.id),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '删除',
            icon: Icon(Icons.delete_outline),
            color: UiPalette.of(context).danger,
            onPressed: () async {
              await confirmInformationDeletion(context, widget.owner, item);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      if (item.description.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.description,
                maxLines:
                    item.description.length > 240 &&
                        !_expandedDescriptions.contains(item.id)
                    ? 4
                    : null,
                overflow:
                    item.description.length > 240 &&
                        !_expandedDescriptions.contains(item.id)
                    ? TextOverflow.ellipsis
                    : null,
              ),
              if (item.description.length > 240)
                TextButton(
                  onPressed: () => setState(() {
                    _expandedDescriptions.contains(item.id)
                        ? _expandedDescriptions.remove(item.id)
                        : _expandedDescriptions.add(item.id);
                  }),
                  child: Text(
                    _expandedDescriptions.contains(item.id) ? '收起说明' : '展开说明',
                  ),
                ),
            ],
          ),
        ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton.icon(
            key: const ValueKey('edit-information-category'),
            onPressed: () async {
              await organizeItem(context, widget.owner, item);
              if (mounted) setState(() {});
            },
            icon: Icon(Icons.folder_outlined, size: 16),
            label: Text(directoryPath(widget.owner, item.directoryId)),
          ),
          for (final tag in widget.owner.tags.where(
            (t) => item.tagIds.contains(t.id),
          ))
            Text(tag.name, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      const SizedBox(height: 16),
      const Divider(),
      for (final field in item.fields) ...[
        InformationValue(
          name: field.name,
          description: field.description,
          value: field.value,
          actions: [
            IconButton(
              tooltip: '修正值',
              icon: Icon(Icons.edit_outlined, size: uiIconSize(context)),
              onPressed: () => _correct(item, field),
            ),
            IconButton(
              tooltip: '删除字段',
              icon: Icon(Icons.delete_outline, size: uiIconSize(context)),
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
        const Divider(),
      ],
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
    if (_name.text.trim().isEmpty ||
        _fields.any((f) => f.name.text.trim().isEmpty)) {
      setState(
        () => _error = _name.text.trim().isEmpty ? '请填写信息名称。' : '请填写每个字段的名称。',
      );
      return;
    }
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
          _error = '未能保存信息。输入已保留，请检查存储状态后重试。';
        });
      }
    }
  }

  Widget _metadata() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SectionHeading('公开目录', detail: 'Agent 可见'),
      Text('名称和说明用于查找。请勿填写秘密。', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 20),
      DesktopTextField(
        key: const ValueKey('item-name'),
        controller: _name,
        enabled: !_saving,
        maxLength: 200,
        decoration: const InputDecoration(
          labelText: '信息名称（公开）',
          hintText: '例如：开发服务器',
        ),
      ),
      DesktopTextField(
        controller: _description,
        enabled: !_saving,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        decoration: const InputDecoration(
          labelText: '公开描述',
          hintText: '说明这份资料的用途',
        ),
      ),
    ],
  );

  Widget _fieldEditors() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SectionHeading('信息字段', detail: '${_fields.length} 个字段 · 按字段授权'),
      for (var i = 0; i < _fields.length; i++) ...[
        if (i > 0)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(),
          ),
        if (_fields.length > 1) ...[
          Text('字段 ${i + 1}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
        ],
        DesktopTextField(
          key: ValueKey('field-name-$i'),
          controller: _fields[i].name,
          enabled: !_saving,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: '字段名称（公开）',
            hintText: '例如：地址',
          ),
        ),
        DesktopTextField(
          controller: _fields[i].description,
          enabled: !_saving,
          maxLength: 2000,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '字段说明（公开）',
            hintText: '帮助 Agent 判断是否需要申请',
          ),
        ),
        DesktopTextField(
          key: ValueKey('field-value-$i'),
          controller: _fields[i].value,
          enabled: !_saving,
          minLines: 4,
          maxLines: 10,
          maxLength: 1000000,
          decoration: const InputDecoration(
            labelText: '字段值或文本说明（需要授权）',
            hintText: '仅在批准对应字段后提供给 Agent',
          ),
        ),
      ],
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _saving || _fields.length >= 200
              ? null
              : () => setState(() => _fields.add(_FieldControllers())),
          icon: Icon(Icons.add, size: 16),
          label: const Text('添加字段'),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= 1080 &&
        MediaQuery.textScalerOf(context).scale(14) <= 20;
    return DesktopDialog(
      title: const Text('新建信息'),
      content: SizedBox(
        width: wide ? 860 : 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 240, child: _metadata()),
                    const SizedBox(width: 32),
                    Expanded(child: _fieldEditors()),
                  ],
                )
              else ...[
                _metadata(),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(),
                ),
                _fieldEditors(),
              ],
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
          child: Text(_saving ? '正在保存…' : '保存信息'),
        ),
      ],
    );
  }
}

class _CorrectValue extends StatefulWidget {
  const _CorrectValue({
    required this.owner,
    required this.item,
    required this.field,
  });
  final OwnerAccess owner;
  final InformationItem item;
  final InformationField field;
  @override
  State<_CorrectValue> createState() => _CorrectValueState();
}

class _CorrectValueState extends State<_CorrectValue> {
  late final _value = TextEditingController(text: widget.field.value);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.owner.correctValue(
        FieldRef(widget.item.id, widget.field.id),
        _value.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，资料未更新。输入已保留，请检查存储后重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text('修正 ${widget.field.name}'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const QuietNotice('仅修正同一含义的值，已有授权会读取新值。若内容含义改变，请新建信息；新信息需要另行授权。'),
            const SizedBox(height: 16),
            DesktopTextField(
              key: const ValueKey('correct-value'),
              controller: _value,
              enabled: !_saving,
              minLines: 4,
              maxLines: 12,
              maxLength: 1000000,
              decoration: const InputDecoration(labelText: '字段值（需要授权）'),
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
        child: Text(_saving ? '正在保存…' : '保存修正'),
      ),
    ],
  );
}
