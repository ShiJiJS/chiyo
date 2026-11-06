import 'library_selection_scope.dart';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'directory_picker.dart';
import 'library_batch_recycle_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

Future<WorkspaceLibraryRecycleReceipt?> showLibraryBatchRecycle(
  BuildContext context,
  WorkspaceSource source, {
  WorkspaceLibrarySelection? selection,
  String? batchId,
}) => showDesktopDialog<WorkspaceLibraryRecycleReceipt>(
  context,
  builder: (_) => _BatchRecycleDialog(source, selection, batchId),
);

class _BatchRecycleDialog extends StatefulWidget {
  const _BatchRecycleDialog(this.source, this.selection, this.batchId);
  final WorkspaceSource source;
  final WorkspaceLibrarySelection? selection;
  final String? batchId;
  @override
  State<_BatchRecycleDialog> createState() => _BatchRecycleDialogState();
}

class _BatchRecycleDialogState extends State<_BatchRecycleDialog> {
  late final LibraryBatchRecycleController m;
  String _nameSearch = '';
  @override
  void initState() {
    super.initState();
    m = LibraryBatchRecycleController(
      widget.source,
      selection: widget.selection,
      batchId: widget.batchId,
    );
    m.load();
  }

  @override
  void dispose() {
    m.dispose();
    super.dispose();
  }

  Future<void> _submit({bool reconcile = false}) async {
    if (reconcile) {
      await m.reconcile();
    } else {
      await m.save();
    }
    if (mounted && m.receipt != null) Navigator.pop(context, m.receipt);
  }

  Future<void> _parent(WorkspaceDirectory d) async {
    final choice = await showDirectoryPicker(
      context,
      m.catalog!,
      selected: d.parentId,
      parentMode: true,
    );
    if (mounted && choice != null) await m.moveRoot(d.id, choice.id);
  }

  Widget _locations(WorkspaceLibraryRecyclePreview p) {
    String searchable(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s*/\s*'), '/');
    final query = searchable(_nameSearch.trim());
    final dirs = orderedLibrarySelectionDirectories(p, m.catalog)
        .where(
          (d) =>
              searchable((p.paths[d.id] ?? [d.name]).join('/')).contains(query),
        )
        .toList();
    return ExpansionTile(
      title: const Text('调整恢复名称和位置'),
      children: [
        TextField(
          key: const ValueKey('batch-restore-search'),
          decoration: const InputDecoration(labelText: '查找要调整的目录'),
          onChanged: (value) => setState(() => _nameSearch = value),
        ),
        if (dirs.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('没有匹配的目录')),
        if (dirs.isNotEmpty)
          SizedBox(
            height: 300,
            child: ListView.builder(
              key: const ValueKey('batch-restore-directories'),
              itemCount: dirs.length,
              itemBuilder: (context, index) {
                final d = dirs[index];
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: ValueKey('batch-restore-name-${d.id}'),
                        initialValue: m.options.names[d.id] ?? d.name,
                        enabled: !m.frozen && !m.reading,
                        maxLength: 200,
                        decoration: const InputDecoration(labelText: '目录名称'),
                        onChanged: (name) => m.rename(d.id, name),
                      ),
                      Text('恢复路径：${(p.paths[d.id] ?? [d.name]).join(' / ')}'),
                      if (p.roots.contains(d.id))
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: ValueKey('batch-restore-parent-${d.id}'),
                            onPressed: m.frozen || m.reading
                                ? null
                                : () => _parent(d),
                            child: const Text('选择恢复上级目录'),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final p = m.preview, c = UiPalette.of(context);
      return PopScope<WorkspaceLibraryRecycleReceipt>(
        canPop: !m.frozen,
        child: DesktopDialog(
          width: 740,
          title: Text(m.restoring ? '恢复目录及内容' : '移到回收站'),
          closeEnabled: !m.frozen,
          content: SizedBox(
            width: 640,
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
                        '${p.directories.length} 个目录、${p.informationCount} 条资料、${p.credentialCount} 项凭据',
                        key: const ValueKey('batch-recycle-counts'),
                        style: libraryText(
                          context,
                          20,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        m.restoring
                            ? '整批恢复原有结构和内容。凭据恢复后保持停用，旧 AI 授权不会恢复。'
                            : '目录和所含资料、凭据一起移到回收站，保留30天。范围外的关联资料保留。',
                      ),
                      if (p.directories.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            p.directories
                                .where(
                                  (d) => !p.directories.any(
                                    (parent) => parent.id == d.parentId,
                                  ),
                                )
                                .map(
                                  (d) =>
                                      (p.paths[d.id] ?? [d.name]).join(' / '),
                                )
                                .join('\n'),
                          ),
                        ),
                      LibrarySelectionScope(preview: p, catalog: m.catalog),
                      if (m.restoring && p.directories.isNotEmpty)
                        _locations(p),
                      for (final warning in p.warnings)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            warning,
                            style: TextStyle(color: c.warning),
                          ),
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
                    if (m.needsReview)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('内容或位置有变化，请更新预览后再保存。'),
                      ),
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
                    key: const ValueKey('batch-recycle-error'),
                    style: TextStyle(color: c.danger),
                  ),
                ),
              ),
            if (m.notice != null)
              SizedBox(width: double.infinity, child: Text(m.notice!)),
            if (m.uncertain)
              DesktopButton(
                key: const ValueKey('batch-recycle-reconcile'),
                onPressed: m.busy ? null : () => _submit(reconcile: true),
                child: const Text('核对原操作结果'),
              ),
            if (!m.uncertain && (m.failure != null || m.needsReview))
              DesktopButton(
                key: const ValueKey('batch-recycle-reload'),
                onPressed: m.frozen || m.reading ? null : m.load,
                child: Text(m.needsReview && m.restoring ? '更新恢复预览' : '重新读取范围'),
              ),
            DesktopButton(
              onPressed: m.frozen ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            DesktopButton(
              key: const ValueKey('batch-recycle-confirm'),
              kind: m.restoring
                  ? DesktopButtonKind.primary
                  : DesktopButtonKind.danger,
              busy: m.busy,
              onPressed: m.canSave ? () => _submit() : null,
              child: Text(m.restoring ? '整体恢复' : '全部移到回收站'),
            ),
          ],
        ),
      );
    },
  );
}
