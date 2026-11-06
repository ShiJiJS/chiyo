import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'directory_picker.dart';
import 'library_move_controller.dart';
import 'library_selection_scope.dart';
import 'workspace_source.dart';

Future<WorkspaceLibraryMoveReceipt?> showLibraryMove(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceLibrarySelection selection, {
  String? initialTarget,
  WorkspaceLibraryPosition? position,
}) => showDesktopDialog<WorkspaceLibraryMoveReceipt>(
  context,
  builder: (_) =>
      _LibraryMoveDialog(source, selection, initialTarget, position),
);

class _LibraryMoveDialog extends StatefulWidget {
  const _LibraryMoveDialog(
    this.source,
    this.selection,
    this.initialTarget,
    this.position,
  );
  final WorkspaceSource source;
  final WorkspaceLibrarySelection selection;
  final String? initialTarget;
  final WorkspaceLibraryPosition? position;
  @override
  State<_LibraryMoveDialog> createState() => _LibraryMoveDialogState();
}

class _LibraryMoveDialogState extends State<_LibraryMoveDialog> {
  late final m = LibraryMoveController(
    widget.source,
    widget.selection,
    targetId: widget.initialTarget,
    position: widget.position,
  );
  @override
  void initState() {
    super.initState();
    m.load();
  }

  @override
  void dispose() {
    m.dispose();
    super.dispose();
  }

  Future<void> _target() async {
    final choice = await showDirectoryPicker(
      context,
      m.catalog!,
      selected: m.targetId,
      parentMode: widget.selection.directoryIds.isNotEmpty,
      excludeSubtrees: widget.selection.directoryIds.toSet(),
    );
    if (mounted && choice != null) await m.chooseTarget(choice.id);
  }

  Future<void> _save({bool reconcile = false}) async {
    if (reconcile) {
      await m.reconcile();
    } else {
      await m.save();
    }
    if (mounted && m.receipt != null) Navigator.pop(context, m.receipt);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final p = m.preview, c = UiPalette.of(context);
      return PopScope<WorkspaceLibraryMoveReceipt>(
        canPop: !m.frozen,
        child: DesktopDialog(
          width: 740,
          title: const Text('移动所选内容'),
          closeEnabled: !m.frozen,
          content: SizedBox(
            width: 680,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .58,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (m.reading) const LinearProgressIndicator(),
                    if (p != null) ...[
                      Text(
                        '${p.scope.directories.length} 个目录、${p.scope.informationCount} 条资料、${p.scope.credentialCount} 项凭据',
                        key: const ValueKey('library-move-counts'),
                      ),
                      const SizedBox(height: 12),
                      const Text('目录及内部内容保持原有层级，只改变存放位置。'),
                      const SizedBox(height: 12),
                      Text(
                        '目标：${p.targetPath.isEmpty ? (p.roots.isEmpty ? '未分类' : '顶层目录') : p.targetPath.join(' / ')}',
                        key: const ValueKey('library-move-target'),
                      ),
                      if (p.targetId == null &&
                          p.roots.isNotEmpty &&
                          p.records.isNotEmpty)
                        const Text('单独选中的资料和凭据会归入“未分类”。'),
                      if (p.position != null)
                        Text(
                          '排在“${p.anchorName}”${p.position!.after ? '之后' : '之前'}',
                          key: const ValueKey('library-move-position'),
                        ),
                    ],
                    if (m.catalog != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DesktopButton(
                          key: const ValueKey('library-move-pick-target'),
                          onPressed: m.frozen || m.reading ? null : _target,
                          child: const Text('选择目标目录'),
                        ),
                      ),
                    if (p != null) ...[
                      LibrarySelectionScope(
                        preview: p.scope,
                        catalog: m.catalog,
                        listKey: const ValueKey('library-move-scope'),
                      ),
                      for (final conflict in p.conflicts)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            conflict,
                            style: TextStyle(color: c.danger),
                          ),
                        ),
                    ],
                    if (m.needsReview) const Text('内容或位置有变化，请重新读取后再移动。'),
                  ],
                ),
              ),
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
                    key: const ValueKey('library-move-error'),
                    style: TextStyle(color: c.danger),
                  ),
                ),
              ),
            if (m.notice != null)
              SizedBox(width: double.infinity, child: Text(m.notice!)),
            if (m.uncertain)
              DesktopButton(
                key: const ValueKey('library-move-reconcile'),
                onPressed: m.busy ? null : () => _save(reconcile: true),
                child: const Text('核对原操作结果'),
              ),
            if (!m.uncertain && (m.failure != null || m.needsReview))
              DesktopButton(
                key: const ValueKey('library-move-reload'),
                onPressed: m.frozen || m.reading ? null : m.load,
                child: const Text('重新读取范围'),
              ),
            DesktopButton(
              onPressed: m.frozen ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            DesktopButton(
              key: const ValueKey('library-move-confirm'),
              kind: DesktopButtonKind.primary,
              busy: m.busy,
              onPressed: m.canSave ? () => _save() : null,
              child: const Text('全部移动'),
            ),
          ],
        ),
      );
    },
  );
}
