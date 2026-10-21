import 'ui.dart';
import 'organization_selectors.dart';
import 'organization_management.dart';
export 'organization_management.dart';
export 'organization_selectors.dart';
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
  return names.isEmpty ? (seen.isEmpty ? '未分类' : '已删除目录') : names.join(' / ');
}

String? organizationRecoveryNotice(
  OwnerAccess owner,
  InformationItem snapshot,
) {
  final missingDirectory =
      snapshot.directoryId != null &&
      !owner.directories.any((d) => d.id == snapshot.directoryId);
  final missingTags = snapshot.tagIds
      .where((id) => !owner.tags.any((t) => t.id == id))
      .length;
  if (!missingDirectory && missingTags == 0) return null;
  return '${[if (missingDirectory) '原目录已删除，恢复后归入未分类', if (missingTags > 0) '已删除的 $missingTags 个标签将跳过'].join('；')}。';
}

Future<void> organizeItem(
  BuildContext context,
  OwnerAccess owner,
  InformationItem item,
) async {
  String? directory = item.directoryId;
  final selected = item.tagIds.toSet();
  var saving = false;
  String? error;
  await showDialog<void>(
    context: context,
    barrierColor: const Color(0x4f241b27),
    builder: (_) => StatefulBuilder(
      builder: (dialogContext, update) => PopScope(
        canPop: !saving,
        child: PrototypeDialog(
          title: '调整目录与标签',
          onClose: saving ? null : () => Navigator.pop(dialogContext),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item.name,
                style: prototypeText(context, 15, weight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              const Text('所属目录'),
              const SizedBox(height: 8),
              DirectoryField(
                directories: owner.directories,
                value: directory,
                enabled: !saving,
                onChanged: (id) => update(() => directory = id),
              ),
              const SizedBox(height: 18),
              const Text('标签'),
              const SizedBox(height: 8),
              SizedBox(
                height: 260,
                child: TagPicker(
                  tags: owner.tags,
                  selected: selected,
                  onChanged: (ids) {
                    if (!saving) {
                      update(() {
                        selected
                          ..clear()
                          ..addAll(ids);
                      });
                    }
                  },
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: prototypeText(
                      context,
                      13,
                      color: UiPalette.of(context).danger,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              style: prototypeSecondary(context),
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              style: prototypePrimary(context),
              onPressed: saving
                  ? null
                  : () async {
                      update(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await owner.organizeInformation(
                          item.id,
                          directoryId: directory,
                          tagIds: selected,
                          expectedVersion: item.version,
                        );
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        if (dialogContext.mounted) {
                          update(() {
                            saving = false;
                            error = organizationError(e);
                          });
                        }
                      }
                    },
              child: Text(saving ? '正在保存…' : '保存整理'),
            ),
          ],
        ),
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
        primary: false,
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
