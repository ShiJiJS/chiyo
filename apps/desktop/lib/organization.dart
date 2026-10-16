import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

String directoryPath(OwnerAccess owner, String? id) {
  final names = <String>[];
  final seen = <String>{};
  while (id != null && seen.add(id)) {
    final found = owner.directories.where((d) => d.id == id);
    if (found.isEmpty) break;
    names.insert(0, found.single.name);
    id = found.single.parentId;
  }
  return names.isEmpty ? '未分类' : names.join(' / ');
}

Future<void> manageOrganization(BuildContext context, OwnerAccess owner) =>
    showDialog<void>(
      context: context,
      builder: (_) => _OrganizationManager(owner: owner),
    );

class _OrganizationManager extends StatefulWidget {
  const _OrganizationManager({required this.owner});
  final OwnerAccess owner;
  @override
  State<_OrganizationManager> createState() => _OrganizationManagerState();
}

class _OrganizationManagerState extends State<_OrganizationManager> {
  Future<void> _edit({
    InformationDirectory? directory,
    InformationTag? tag,
    bool isTag = false,
  }) async {
    var name = directory?.name ?? tag?.name ?? '';
    String? parentId = directory?.parentId;
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => DesktopDialog(
          title: Text(
            isTag
                ? (tag == null ? '新建标签' : '编辑标签')
                : (directory == null ? '新建目录' : '编辑目录'),
          ),
          content: SizedBox(
            width: 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DesktopTextFormField(
                  key: const ValueKey('organization-name'),
                  initialValue: name,
                  onChanged: (value) => name = value,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '名称（仅用于本人整理）'),
                ),
                if (!isTag)
                  DesktopSelect<String>(
                    key: const ValueKey('organization-parent'),
                    initialValue: parentId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '上级目录'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('根目录')),
                      for (final candidate in widget.owner.directories.where(
                        (d) => d.id != directory?.id,
                      ))
                        DropdownMenuItem(
                          value: candidate.id,
                          child: Text(
                            directoryPath(widget.owner, candidate.id),
                          ),
                        ),
                    ],
                    onChanged: saving
                        ? null
                        : (value) => setDialogState(() => parentId = value),
                  ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setDialogState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        if (isTag) {
                          if (tag == null) {
                            await widget.owner.createTag(name);
                          } else {
                            await widget.owner.updateTag(tag.id, name);
                          }
                        } else {
                          if (directory == null) {
                            await widget.owner.createDirectory(
                              name,
                              parentId: parentId,
                            );
                          } else {
                            await widget.owner.updateDirectory(
                              directory.id,
                              name,
                              parentId: parentId,
                            );
                          }
                        }
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (context.mounted) {
                          setDialogState(() {
                            saving = false;
                            error = '保存失败，请检查名称、上级目录和存储状态。目录不能移动到自身下级。';
                          });
                        }
                      }
                    },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('目录与标签'),
    content: SizedBox(
      width: 650,
      height: 500,
      child: ListView(
        children: [
          const Text('目录和标签用于整理。名称仅在客户端展示；Agent 目录只提供必要标识及已保存的公开说明。'),
          TextButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新建目录'),
          ),
          for (final directory in widget.owner.directories)
            ListTile(
              title: Text(directoryPath(widget.owner, directory.id)),
              trailing: IconButton(
                tooltip: '编辑目录',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(directory: directory),
              ),
            ),
          const Divider(),
          TextButton.icon(
            onPressed: () => _edit(isTag: true),
            icon: const Icon(Icons.new_label_outlined),
            label: const Text('新建标签'),
          ),
          for (final tag in widget.owner.tags)
            ListTile(
              title: Text(tag.name),
              trailing: IconButton(
                tooltip: '编辑标签',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(tag: tag, isTag: true),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

Future<void> organizeItem(
  BuildContext context,
  OwnerAccess owner,
  InformationItem item,
) async {
  String? directoryId = item.directoryId;
  final selected = item.tagIds.toSet();
  var saving = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => DesktopDialog(
        title: const Text('整理位置和标签'),
        content: SizedBox(
          width: 550,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('移动和标签变化不改变既有授权范围。目录批量选择只包含批准当时的字段。'),
                DesktopSelect<String>(
                  key: const ValueKey('item-directory'),
                  initialValue: directoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '目录'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('未分类')),
                    for (final directory in owner.directories)
                      DropdownMenuItem(
                        value: directory.id,
                        child: Text(directoryPath(owner, directory.id)),
                      ),
                  ],
                  onChanged: saving
                      ? null
                      : (value) => setDialogState(() => directoryId = value),
                ),
                for (final tag in owner.tags)
                  CheckboxListTile(
                    title: Text(tag.name),
                    value: selected.contains(tag.id),
                    onChanged: saving
                        ? null
                        : (value) => setDialogState(() {
                            if (value == true) {
                              selected.add(tag.id);
                            } else {
                              selected.remove(tag.id);
                            }
                          }),
                  ),
                if (error != null) Text(error!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setDialogState(() {
                      saving = true;
                      error = null;
                    });
                    try {
                      await owner.organizeInformation(
                        item.id,
                        directoryId: directoryId,
                        tagIds: selected,
                      );
                      if (context.mounted) Navigator.pop(context);
                    } catch (_) {
                      if (context.mounted) {
                        setDialogState(() {
                          saving = false;
                          error = '保存失败，请检查资料和存储状态。';
                        });
                      }
                    }
                  },
            child: const Text('保存整理'),
          ),
        ],
      ),
    ),
  );
}

Future<void> editCatalogMetadata(
  BuildContext context,
  OwnerAccess owner,
  InformationItem item,
) => showDialog<void>(
  context: context,
  builder: (_) => _CatalogEditor(owner: owner, item: item),
);

class _CatalogEditor extends StatefulWidget {
  const _CatalogEditor({required this.owner, required this.item});
  final OwnerAccess owner;
  final InformationItem item;
  @override
  State<_CatalogEditor> createState() => _CatalogEditorState();
}

class _CatalogEditorState extends State<_CatalogEditor> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _description = TextEditingController(
    text: widget.item.description,
  );
  late final _fields = {
    for (final f in widget.item.fields)
      f.id: TextEditingController(text: f.description),
  };
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final field in _fields.values) {
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
      await widget.owner.updateCatalogMetadata(
        widget.item.id,
        name: _name.text,
        description: _description.text,
        fieldDescriptions: {
          for (final field in _fields.entries) field.key: field.value.text,
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请检查名称、长度和存储状态。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('编辑公开说明'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '保存后 Agent 无需内容授权即可看到以下文字，请检查是否适合公开。字段名称表示固定含义；若含义改变，请新建信息并重新申请授权。',
            ),
            DesktopTextField(
              key: const ValueKey('catalog-name'),
              controller: _name,
              maxLength: 200,
              decoration: const InputDecoration(labelText: '信息名称（公开）'),
            ),
            DesktopTextField(
              key: const ValueKey('catalog-description'),
              controller: _description,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '公开描述'),
            ),
            for (final field in widget.item.fields)
              DesktopTextField(
                key: ValueKey('catalog-field-${field.id}'),
                controller: _fields[field.id],
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: '${field.name}：字段说明（公开）',
                ),
              ),
            if (_error != null) Text(_error!),
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
        child: const Text('保存公开说明'),
      ),
    ],
  );
}
