import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'classification_controller.dart';
import 'library_controller.dart';
import 'library_widgets.dart';
import 'library_batch_recycle_dialog.dart';
import 'workspace_source.dart';

Future<bool> showLibraryDirectoryEditor(
  BuildContext context,
  LibraryController controller, {
  required WorkspaceDirectoryAction action,
  WorkspaceDirectory? directory,
  String? initialParent,
}) async {
  final catalog = controller.catalog;
  if (catalog == null) return false;
  if (action == WorkspaceDirectoryAction.delete &&
      directory != null &&
      controller.source is WorkspaceLibraryRecycle &&
      (controller.source as WorkspaceLibraryRecycle).libraryRecycleSupported) {
    return await showLibraryBatchRecycle(
          context,
          controller.source,
          selection: WorkspaceLibrarySelection(directoryIds: [directory.id]),
        ) !=
        null;
  }
  return await showClassificationEditor(
        context,
        controller.source,
        catalog,
        kind: WorkspaceClassificationKind.directory,
        action: action.name,
        directory: directory,
        initialParent: initialParent,
      ) !=
      null;
}

Future<WorkspaceClassificationReceipt?> showClassificationEditor(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceCatalog catalog, {
  required WorkspaceClassificationKind kind,
  required String action,
  WorkspaceDirectory? directory,
  WorkspaceTag? tag,
  String? initialParent,
}) => showDesktopDialog<WorkspaceClassificationReceipt>(
  context,
  builder: (_) => _ClassificationEditor(
    source: source,
    catalog: catalog,
    kind: kind,
    action: action,
    directory: directory,
    tag: tag,
    initialParent: initialParent,
  ),
);

class _ClassificationEditor extends StatefulWidget {
  const _ClassificationEditor({
    required this.source,
    required this.catalog,
    required this.kind,
    required this.action,
    this.directory,
    this.tag,
    this.initialParent,
  });
  final WorkspaceSource source;
  final WorkspaceCatalog catalog;
  final WorkspaceClassificationKind kind;
  final String action;
  final WorkspaceDirectory? directory;
  final WorkspaceTag? tag;
  final String? initialParent;
  @override
  State<_ClassificationEditor> createState() => _ClassificationEditorState();
}

class _ClassificationEditorState extends State<_ClassificationEditor> {
  late final ClassificationEditController m;
  late final TextEditingController _name;
  bool _discard = false;
  String get _noun => m.tag ? '标签' : '目录';
  String get _title => m.deleting
      ? m.tag
            ? '删除标签'
            : '删除空目录'
      : widget.action == 'create'
      ? '新建$_noun'
      : m.tag
      ? '重命名标签'
      : '重命名或移动目录';
  @override
  void initState() {
    super.initState();
    m = ClassificationEditController(
      widget.source,
      widget.catalog,
      kind: widget.kind,
      action: widget.action,
      targetId: widget.directory?.id ?? widget.tag?.id,
      initialName: widget.directory?.name ?? widget.tag?.name ?? '',
      initialParent: widget.directory?.parentId ?? widget.initialParent,
    );
    _name = TextEditingController(text: m.name);
    if (m.tag && m.deleting) Future<void>.microtask(m.readRemoval);
  }

  @override
  void dispose() {
    m.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit(bool reconcile) async {
    if (reconcile) {
      await m.reconcile();
    } else {
      await m.save();
    }
    if (!mounted || m.receipt == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, m.receipt);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final c = UiPalette.of(context);
      final currentName = m.tag
          ? m.catalog.tags.where((t) => t.id == m.targetId).firstOrNull?.name ??
                m.name
          : m.catalog.directories
                    .where((d) => d.id == m.targetId)
                    .firstOrNull
                    ?.name ??
                m.name;
      return PopScope<WorkspaceClassificationReceipt>(
        canPop: !m.frozen && !m.dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !m.frozen) setState(() => _discard = true);
        },
        child: DesktopDialog(
          width: 560,
          title: Text(_title),
          closeEnabled: !m.frozen,
          content: SizedBox(
            width: 460,
            child: m.deleting
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        m.tag
                            ? '删除“$currentName”？只移除当前资料和凭据上的这个标记，不删除资料或凭据。'
                            : '删除“$currentName”？仅能删除没有资料、凭据和子目录的空目录；不会删除或重写历史资料。',
                      ),
                      if (m.tag) ...[
                        const SizedBox(height: 16),
                        if (m.reading) const LinearProgressIndicator(),
                        if (m.removal != null)
                          Text(
                            '将影响 ${m.removal!.affectedCount} 条当前资料或凭据。',
                            key: const ValueKey('classification-removal-count'),
                          ),
                        const SizedBox(height: 12),
                        const Text(
                          '历史修订和回收站保留原标签引用；以后恢复资料时不会重建这个标签。影响范围变化时需要重新核对。',
                        ),
                      ],
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DesktopTextField(
                        key: ValueKey(
                          m.tag
                              ? 'classification-tag-name'
                              : 'library-directory-name',
                        ),
                        controller: _name,
                        enabled: !m.frozen && !m.reading,
                        onChanged: (value) {
                          m.edit(name: value);
                          setState(() => _discard = false);
                        },
                        decoration: InputDecoration(
                          labelText: '$_noun名称',
                          errorText: m.failure?.fieldErrors['name'],
                        ),
                      ),
                      if (!m.tag) ...[
                        const SizedBox(height: 18),
                        LibraryDirectorySelect(
                          key: const ValueKey('library-directory-parent'),
                          catalog: m.catalog,
                          value: m.parent,
                          parentMode: true,
                          parentFor: widget.directory?.id,
                          errorText: m.failure?.fieldErrors['parent'],
                          onChanged: m.frozen || m.reading
                              ? null
                              : (parent) {
                                  m.edit(parent: parent, changeParent: true);
                                  setState(() => _discard = false);
                                },
                        ),
                      ],
                    ],
                  ),
          ),
          actions: [
            if (m.failure != null)
              SizedBox(
                width: double.infinity,
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    m.failure!.message,
                    key: ValueKey(
                      m.tag
                          ? 'classification-error'
                          : 'library-directory-error',
                    ),
                    style: TextStyle(
                      color: m.failure!.code == 'review' ? c.muted : c.danger,
                    ),
                  ),
                ),
              ),
            if (m.failure?.code == 'conflict')
              DesktopButton(
                key: const ValueKey('classification-reload'),
                onPressed: m.frozen || m.reading ? null : m.reload,
                child: Text(m.tag ? '重新读取标签' : '重新读取目录'),
              ),
            if (m.tag &&
                m.deleting &&
                m.failure != null &&
                m.failure?.code != 'conflict' &&
                !m.uncertain &&
                m.removal == null)
              DesktopButton(
                key: const ValueKey('classification-removal-retry'),
                onPressed: m.reading ? null : m.readRemoval,
                child: const Text('重新读取影响范围'),
              ),
            if (m.uncertain)
              DesktopButton(
                key: const ValueKey('classification-reconcile'),
                onPressed: m.busy ? null : () => _submit(true),
                child: const Text('核对原分类操作'),
              ),
            if (_discard) ...[
              SizedBox(
                width: double.infinity,
                child: Text(
                  '尚有未保存的$_noun修改。',
                  style: TextStyle(color: c.warning),
                ),
              ),
              DesktopButton(
                onPressed: m.frozen
                    ? null
                    : () {
                        m.dirty = false;
                        Navigator.pop(context);
                      },
                child: const Text('放弃修改'),
              ),
            ],
            DesktopButton(
              onPressed: m.frozen
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
              key: ValueKey(
                m.tag ? 'classification-tag-save' : 'library-directory-save',
              ),
              kind: m.deleting
                  ? DesktopButtonKind.danger
                  : DesktopButtonKind.primary,
              busy: m.busy,
              onPressed: m.canSave ? () => _submit(false) : null,
              child: Text(
                m.busy
                    ? '正在保存…'
                    : m.deleting
                    ? '删除$_noun'
                    : '保存$_noun',
              ),
            ),
          ],
        ),
      );
    },
  );
}
