import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization_selectors.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

enum DirectoryOperation { create, rename, move, delete }

String organizationError(Object error) => switch (error) {
  AccessFailure(status: 'duplicate_directory') => '此位置已有同名目录。',
  AccessFailure(status: 'duplicate_tag') => '已有同名标签。',
  AccessFailure(status: 'invalid_directory_name') => '请输入单级目录名称，不要填写路径。',
  AccessFailure(status: 'directory_not_empty') => '请先移动目录中的信息和子目录。',
  AccessFailure(status: 'organization_conflict' || 'information_conflict') =>
    '内容已变化，请核对后重新打开操作。',
  AccessFailure(status: 'invalid_information') => '请检查名称和所选位置。目录不能移入自身或下级。',
  _ => '保存失败，输入已保留，请重试。',
};

Future<String?> editDirectory(
  BuildContext context,
  OwnerAccess owner, {
  InformationDirectory? directory,
  String? parentId,
  DirectoryOperation operation = DirectoryOperation.create,
}) => showDialog<String>(
  context: context,
  barrierColor: const Color(0x4f241b27),
  builder: (_) => _DirectoryEditor(
    owner: owner,
    directory: directory,
    parentId: parentId,
    operation: operation,
  ),
);

class _DirectoryEditor extends StatefulWidget {
  const _DirectoryEditor({
    required this.owner,
    required this.directory,
    required this.parentId,
    required this.operation,
  });
  final OwnerAccess owner;
  final InformationDirectory? directory;
  final String? parentId;
  final DirectoryOperation operation;
  @override
  State<_DirectoryEditor> createState() => _DirectoryEditorState();
}

class _DirectoryEditorState extends State<_DirectoryEditor> {
  late final _name = TextEditingController(text: widget.directory?.name ?? '');
  late String? _parent = widget.directory?.parentId ?? widget.parentId;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = widget.directory;
      String? id;
      switch (widget.operation) {
        case DirectoryOperation.create:
          id = (await widget.owner.createDirectory(
            _name.text,
            parentId: _parent,
          )).id;
        case DirectoryOperation.rename:
        case DirectoryOperation.move:
          id = (await widget.owner.updateDirectory(
            d!.id,
            _name.text,
            parentId: _parent,
            expectedVersion: d.version,
          )).id;
        case DirectoryOperation.delete:
          await widget.owner.deleteDirectory(d!.id, d.version);
          id = d.parentId ?? '';
      }
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = organizationError(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final operation = widget.operation;
    final deleting = operation == DirectoryOperation.delete;
    final d = widget.directory;
    final count = widget.owner.information
        .where((i) => i.directoryId == d?.id)
        .length;
    final children = widget.owner.directories
        .where((c) => c.parentId == d?.id)
        .length;
    final nonempty = deleting && (count > 0 || children > 0);
    return PopScope(
      canPop: !_busy,
      child: PrototypeDialog(
        title: switch (operation) {
          DirectoryOperation.create => '新建目录',
          DirectoryOperation.rename => '重命名目录',
          DirectoryOperation.move => '移动目录',
          DirectoryOperation.delete => '删除目录',
        },
        onClose: _busy ? null : () => Navigator.pop(context),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (deleting) ...[
              Text('删除“${d!.name}”？'),
              const SizedBox(height: 12),
              Text(
                nonempty
                    ? '包含 $count 条信息、$children 个子目录，请先移动后再删除。'
                    : '这是空目录。删除后，回收内容恢复时将归入未分类。',
                style: prototypeText(
                  context,
                  13,
                  color: UiPalette.of(context).muted,
                ),
              ),
            ] else ...[
              if (operation == DirectoryOperation.move)
                Text('将“${d!.name}”移到新位置')
              else
                TextField(
                  key: const ValueKey('organization-name'),
                  controller: _name,
                  enabled: !_busy,
                  autofocus: true,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: '目录名称',
                    hintText: '例如：运维',
                  ),
                ),
              if (operation != DirectoryOperation.rename) ...[
                const SizedBox(height: 16),
                const Text('上级目录'),
                const SizedBox(height: 10),
                SizedBox(
                  height: 260,
                  child: DirectoryTreePicker(
                    key: const ValueKey('organization-parent'),
                    directories: widget.owner.directories,
                    selected: _parent,
                    excludeId: d?.id,
                    rootLabel: '根目录',
                    onSelected: (id) {
                      if (!_busy) setState(() => _parent = id);
                    },
                  ),
                ),
              ],
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
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
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            style: prototypePrimary(context),
            onPressed: _busy || nonempty ? null : _save,
            child: Text(
              _busy
                  ? '正在保存…'
                  : deleting
                  ? '删除'
                  : operation == DirectoryOperation.create
                  ? '创建'
                  : '保存',
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> manageTags(BuildContext context, OwnerAccess owner) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => _TagManager(owner),
    );

class _TagManager extends StatefulWidget {
  const _TagManager(this.owner);
  final OwnerAccess owner;
  @override
  State<_TagManager> createState() => _TagManagerState();
}

class _TagManagerState extends State<_TagManager> {
  String _query = '';
  Map<String, int> _deleteReview = {};
  final _name = TextEditingController();
  InformationTag? _editing, _deleting;
  bool _creating = false, _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_deleting case final t?) {
        await widget.owner.deleteTag(
          t.id,
          t.version,
          reviewedInformation: _deleteReview,
        );
      } else if (_editing case final t?) {
        await widget.owner.updateTag(
          t.id,
          _name.text,
          expectedVersion: t.version,
        );
      } else {
        await widget.owner.createTag(_name.text);
      }
      if (mounted) {
        setState(() {
          _editing = null;
          _deleting = null;
          _creating = false;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = organizationError(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: PrototypeDialog(
      title: _deleting == null ? '管理标签' : '删除标签',
      onClose: _busy ? null : () => Navigator.pop(context),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_deleting case final t?) ...[
            Text('删除标签“${t.name}”？'),
            const SizedBox(height: 12),
            Text(
              '将移除 ${widget.owner.information.where((i) => i.tagIds.contains(t.id)).length} 条信息的标记。信息、附件和已有内容授权会保留。',
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '搜索标签',
                      prefixIcon: Icon(Icons.search, size: 17),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  style: prototypeSecondary(context),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _creating = true;
                          _editing = null;
                          _name.clear();
                          _error = null;
                        }),
                  child: const Text('新建标签'),
                ),
              ],
            ),
            if (_creating || _editing != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('tag-name'),
                        controller: _name,
                        enabled: !_busy,
                        decoration: const InputDecoration(hintText: '标签名称'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _busy ? null : _save,
                      child: const Text('保存'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _creating = false;
                              _editing = null;
                            }),
                      child: const Text('取消编辑'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              height: 280,
              child: ListView(
                primary: false,
                children: [
                  for (final t in widget.owner.tags.where(
                    (t) => t.name.toLowerCase().contains(_query.toLowerCase()),
                  ))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              t.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${widget.owner.information.where((i) => i.tagIds.contains(t.id)).length} 条',
                            style: prototypeText(
                              context,
                              12,
                              color: UiPalette.of(context).muted,
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _editing = t;
                                    _creating = false;
                                    _name.text = t.name;
                                    _error = null;
                                  }),
                            child: const Text('重命名'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _deleting = t;
                                    _deleteReview = {
                                      for (final i
                                          in widget.owner.information.where(
                                            (i) => i.tagIds.contains(t.id),
                                          ))
                                        i.id: i.version,
                                    };
                                    _error = null;
                                  }),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    ),
                  if (widget.owner.tags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('还没有标签'),
                    ),
                ],
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: prototypeText(
                  context,
                  13,
                  color: UiPalette.of(context).danger,
                ),
              ),
            ),
        ],
      ),
      actions: _deleting == null
          ? [
              TextButton(
                style: prototypeSecondary(context),
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ]
          : [
              TextButton(
                style: prototypeSecondary(context),
                onPressed: _busy
                    ? null
                    : () => setState(() => _deleting = null),
                child: const Text('取消'),
              ),
              FilledButton(
                style: prototypePrimary(context),
                onPressed: _busy ? null : _save,
                child: Text(_busy ? '正在删除…' : '删除'),
              ),
            ],
    ),
  );
}
