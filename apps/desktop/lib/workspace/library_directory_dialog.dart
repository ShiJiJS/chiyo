import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

Future<bool> showLibraryDirectoryEditor(
  BuildContext context,
  LibraryController controller, {
  required WorkspaceDirectoryAction action,
  WorkspaceDirectory? directory,
  String? initialParent,
}) async {
  if (controller.catalog == null) return false;
  return await showDesktopDialog<bool>(
        context,
        builder: (_) => _DirectoryEditor(
          controller: controller,
          action: action,
          directory: directory,
          initialParent: initialParent,
        ),
      ) ??
      false;
}

class _DirectoryEditor extends StatefulWidget {
  const _DirectoryEditor({
    required this.controller,
    required this.action,
    this.directory,
    this.initialParent,
  });
  final LibraryController controller;
  final WorkspaceDirectoryAction action;
  final WorkspaceDirectory? directory;
  final String? initialParent;
  @override
  State<_DirectoryEditor> createState() => _DirectoryEditorState();
}

class _DirectoryEditorState extends State<_DirectoryEditor> {
  late WorkspaceCatalog _catalog;
  late final TextEditingController _name;
  String? _parent;
  bool _busy = false, _dirty = false, _discard = false;
  WorkspaceFailure? _failure;
  static int _operation = 0;
  bool get _deleting => widget.action == WorkspaceDirectoryAction.delete;
  String get _title => switch (widget.action) {
    WorkspaceDirectoryAction.create => '新建目录',
    WorkspaceDirectoryAction.update => '重命名或移动目录',
    WorkspaceDirectoryAction.delete => '删除空目录',
  };
  @override
  void initState() {
    super.initState();
    _catalog = widget.controller.catalog!;
    _name = TextEditingController(text: widget.directory?.name ?? '');
    _parent = widget.directory?.parentId ?? widget.initialParent;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
    _dirty = true;
    _discard = false;
  });

  Future<void> _reload() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final catalog = await widget.controller.source.loadCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        if (_parent != null &&
            !catalog.directories.any((d) => d.id == _parent)) {
          _parent = null;
        }
        _failure = const WorkspaceFailure(
          'review',
          '已重新读取目录；草稿保留，请核对名称和上级目录后再保存。',
        );
      });
    } on WorkspaceFailure catch (error) {
      if (mounted) setState(() => _failure = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _failure = const WorkspaceFailure(
            'unavailable',
            '暂时无法读取目录，请稍后重试。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await widget.controller.source.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'directory-form-${_operation++}',
          expectedVersion: _catalog.version,
          action: widget.action,
          directoryId: widget.directory?.id,
          name: _name.text,
          parentId: _parent,
        ),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _dirty = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    } on WorkspaceFailure catch (error) {
      if (mounted) setState(() => _failure = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _failure = const WorkspaceFailure(
            'unknown_outcome',
            '目录操作结果暂时无法确认，请先关闭并核对目录，不要重复提交。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return PopScope<bool>(
      canPop: !_busy && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) setState(() => _discard = true);
      },
      child: DesktopDialog(
        width: 560,
        title: Text(_title),
        content: SizedBox(
          width: 460,
          child: _deleting
              ? Text(
                  '删除“${widget.directory!.name}”？仅能删除没有资料、凭据和子目录的空目录；不会删除或重写历史资料。',
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DesktopTextField(
                      key: const ValueKey('library-directory-name'),
                      controller: _name,
                      enabled: !_busy,
                      onChanged: (_) => _changed(),
                      decoration: InputDecoration(
                        labelText: '目录名称',
                        errorText: _failure?.fieldErrors['name'],
                      ),
                    ),
                    const SizedBox(height: 18),
                    LibraryDirectorySelect(
                      key: const ValueKey('library-directory-parent'),
                      catalog: _catalog,
                      value: _parent,
                      parentMode: true,
                      parentFor: widget.directory?.id,
                      errorText: _failure?.fieldErrors['parent'],
                      onChanged: _busy
                          ? null
                          : (parent) {
                              _parent = parent;
                              _changed();
                            },
                    ),
                  ],
                ),
        ),
        actions: [
          if (_failure != null)
            SizedBox(
              width: double.infinity,
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _failure!.message,
                  key: const ValueKey('library-directory-error'),
                  style: TextStyle(
                    color: _failure!.code == 'review' ? c.muted : c.danger,
                  ),
                ),
              ),
            ),
          if (_failure?.code == 'conflict')
            DesktopButton(
              onPressed: _busy ? null : _reload,
              child: const Text('重新读取目录'),
            ),
          if (_discard) ...[
            SizedBox(
              width: double.infinity,
              child: Text('尚有未保存的目录修改。', style: TextStyle(color: c.warning)),
            ),
            DesktopButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _dirty = false);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) Navigator.pop(context, false);
                      });
                    },
              child: const Text('放弃修改'),
            ),
          ],
          DesktopButton(
            onPressed: _busy
                ? null
                : () {
                    if (_discard) {
                      setState(() => _discard = false);
                    } else {
                      Navigator.maybePop(context);
                    }
                  },
            child: Text(_discard ? '继续编辑' : '取消'),
          ),
          DesktopButton(
            key: const ValueKey('library-directory-save'),
            kind: _deleting
                ? DesktopButtonKind.danger
                : DesktopButtonKind.primary,
            busy: _busy,
            onPressed:
                _failure?.code == 'unknown_outcome' ||
                    _failure?.code == 'conflict'
                ? null
                : _save,
            child: Text(
              _busy
                  ? '正在保存…'
                  : _deleting
                  ? '删除目录'
                  : '保存目录',
            ),
          ),
        ],
      ),
    );
  }
}
