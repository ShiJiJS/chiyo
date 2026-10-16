import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';

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

Future<void> manageOrganization(
  BuildContext context,
  OwnerAccess owner, {
  ValueChanged<String>? onSelectDirectory,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x4f241b27),
  builder: (_) =>
      _OrganizationManager(owner: owner, onSelectDirectory: onSelectDirectory),
);

class _OrganizationManager extends StatefulWidget {
  const _OrganizationManager({required this.owner, this.onSelectDirectory});
  final OwnerAccess owner;
  final ValueChanged<String>? onSelectDirectory;
  @override
  State<_OrganizationManager> createState() => _OrganizationManagerState();
}

class _OrganizationManagerState extends State<_OrganizationManager> {
  final _newName = TextEditingController();
  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  Future<void> _edit({
    InformationDirectory? directory,
    InformationTag? tag,
    bool isTag = false,
  }) async {
    var name = directory?.name ?? tag?.name ?? (isTag ? '' : _newName.text);
    String? parentId = directory?.parentId;
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => PrototypeDialog(
          title: isTag
              ? (tag == null ? '新建标签' : '编辑标签')
              : (directory == null ? '新建目录' : '编辑目录'),
          onClose: saving ? null : () => Navigator.pop(context),
          body: SizedBox(
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
              style: prototypeSecondary(context),
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              style: prototypePrimary(context),
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
  Widget build(BuildContext context) => PrototypeDialog(
    flow: true,
    scrollGutter: 0,
    title: '目录与标签',
    onClose: () => Navigator.pop(context),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: prototypeCh(context, 14, 48)),
            child: Text(
              '目录可有父子层级，移动目录保留信息身份。标签用于跨目录筛选。',
              style: prototypeText(
                context,
                14,
                height: 1.85,
                color: UiPalette.of(context).muted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12.3),
        Text('新目录名称', style: prototypeText(context, 13)),
        const SizedBox(height: 8),
        SizedBox(
          height: 39.5,
          child: TextField(
            controller: _newName,
            style: prototypeText(context, 13),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.all(9),
              hintText: '工作/北辰项目/运维',
              filled: true,
              fillColor: UiPalette.of(context).paper,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => _edit(),
            style: prototypeSecondary(context),
            child: const Text('添加目录'),
          ),
        ),
        for (final directory in widget.owner.directories)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 22.75),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    directoryPath(widget.owner, directory.id),
                    style: prototypeText(context, 13),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TextButton(
                    style: prototypeButton(context, size: 12),
                    onPressed: () => _edit(directory: directory),
                    child: const Text('编辑'),
                  ),
                ),
                TextButton(
                  style: prototypeButton(
                    context,
                    size: 13,
                    foreground: UiPalette.of(context).accent,
                  ),
                  onPressed: () {
                    widget.onSelectDirectory?.call(directory.id);
                    Navigator.pop(context);
                  },
                  child: const Text('查看信息 →'),
                ),
              ],
            ),
          ),
        const Divider(),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _edit(isTag: true),
            style: prototypeSecondary(context),
            icon: const Icon(Icons.new_label_outlined),
            label: const Text('新建标签'),
          ),
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
        title: const Text('调整分类'),
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
    title: const Text('编辑信息说明'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '保存后 Agent 无需内容授权即可看到以下文字，请检查是否适合公开。字段名称表示固定含义；若含义改变，请新建信息并重新申请授权。',
            ),
            const SizedBox(height: 20),
            const SectionHeading('公开目录', detail: 'Agent 可见'),
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
              decoration: const InputDecoration(labelText: '信息说明（Agent 可见）'),
            ),
            const SizedBox(height: 12),
            const SectionHeading('字段说明', detail: '字段含义保持不变'),
            for (final field in widget.item.fields)
              DesktopTextField(
                key: ValueKey('catalog-field-${field.id}'),
                controller: _fields[field.id],
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: '${field.name}：字段说明（公开）',
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
      FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
    ],
  );
}
