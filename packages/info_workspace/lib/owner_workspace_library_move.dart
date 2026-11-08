import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart' show StorageFailure;
import 'owner_library_selection.dart';
import 'workspace_source.dart';
import 'directory_tree.dart';

class OwnerWorkspaceLibraryMove {
  OwnerWorkspaceLibraryMove(this.owner, this.catalog, this.changed);
  final core.OwnerAccess owner;
  final Future<WorkspaceCatalog> Function() catalog;
  final void Function() changed;
  core.LibraryMovePosition? _position(WorkspaceLibraryPosition? position) =>
      position == null
      ? null
      : core.LibraryMovePosition(
          core.LibraryEntryRef(position.kind, position.id),
          after: position.after,
        );
  Future<T> _run<T>(Future<T> Function() action, {bool writing = false}) async {
    try {
      return await action();
    } on core.AccessFailure catch (e) {
      throw switch (e.status) {
        'library_selection_changed' => const WorkspaceFailure(
          'conflict',
          '目录或资料已变化，请重新读取并核对范围。',
        ),
        'library_changed' => const WorkspaceFailure(
          'library_changed',
          '资料库已替换，请重新打开窗口。',
        ),
        'move_target_missing' => const WorkspaceFailure(
          'conflict',
          '目标目录已移除，请重新选择位置。',
        ),
        'library_move_conflict' => const WorkspaceFailure(
          'conflict',
          '移动位置存在冲突，请重新核对目标。',
        ),
        'operation_conflict' => const WorkspaceFailure(
          'operation_conflict',
          '原操作不能用于另一份移动决定。',
        ),
        _ => const WorkspaceFailure('unavailable', '暂时无法移动，请重新读取。'),
      };
    } on StorageFailure {
      throw const WorkspaceFailure('save_failed', '保存失败，原位置没有改变，可以重试。');
    } on WorkspaceFailure {
      rethrow;
    } catch (_) {
      throw WorkspaceFailure(
        writing ? 'unknown_outcome' : 'unavailable',
        writing ? '移动结果暂时无法确认，请先核对原操作。' : '暂时无法读取移动范围，请重试。',
      );
    }
  }

  WorkspaceLibraryMoveReceipt _receipt(core.LibraryMoveReceipt receipt) =>
      WorkspaceLibraryMoveReceipt(
        operationId: receipt.operationId,
        inputHash: receipt.inputHash,
        targetId: receipt.targetId,
      );
  Future<List<WorkspaceLibraryPlacementTarget>> targets(
    WorkspaceLibrarySelection selection,
  ) => _run(() async {
    final c = await catalog(),
        p = await owner.previewLibraryMove(
          coreLibrarySelection(selection),
          null,
        );
    if (p.roots.isNotEmpty && p.records.isNotEmpty) {
      throw const WorkspaceFailure(
        'validation',
        '目录和单独选中的资料请分别调整顺序；一起移动可以选择目标目录。',
      );
    }
    if (p.roots.isNotEmpty) {
      final selected = p.scope.directories.map((d) => d.id).toSet();
      return [
        for (final d in libraryDirectoryTree(c))
          if (!libraryVirtualDirectoryIds.contains(d.id) &&
              !selected.contains(d.id))
            WorkspaceLibraryPlacementTarget(
              kind: 'directory',
              id: d.id,
              name: d.name,
              type: '目录',
              path: directoryPath(c, d.id),
              directoryId: d.parentId,
            ),
      ];
    }
    final selected = {for (final r in p.records) '${r.kind}:${r.id}'};
    final entries = <String, WorkspaceLibraryPlacementTarget>{
      for (final i in owner.information)
        if (!selected.contains('information:${i.id}'))
          'information:${i.id}': WorkspaceLibraryPlacementTarget(
            kind: 'information',
            id: i.id,
            name: i.name,
            type:
                c.types
                    .where((t) => t.id == (i.layout?.typeId ?? 'generic'))
                    .firstOrNull
                    ?.name ??
                '资料',
            path: directoryPath(c, i.directoryId),
            directoryId: i.directoryId,
          ),
      for (final item in owner.credentials)
        if (!selected.contains('credential:${item.id}'))
          'credential:${item.id}': WorkspaceLibraryPlacementTarget(
            kind: 'credential',
            id: item.id,
            name: item.name,
            type: '凭据',
            path: directoryPath(c, item.directoryId),
            directoryId: item.directoryId,
          ),
    };
    return [
      for (final r in owner.libraryRecordsInOrder)
        if (entries['${r.kind}:${r.id}'] != null) entries['${r.kind}:${r.id}']!,
    ];
  });
  Future<WorkspaceLibraryMovePreview> preview(
    WorkspaceLibrarySelection selection,
    String? targetId, {
    WorkspaceLibraryPosition? position,
  }) => _run(() async {
    final c = await catalog(),
        p = await owner.previewLibraryMove(
          coreLibrarySelection(selection),
          targetId,
          position: _position(position),
        );
    return WorkspaceLibraryMovePreview(
      scope: WorkspaceLibraryRecyclePreview(
        token: p.scope.token,
        directories: p.scope.directories.map(
          (d) => WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
        ),
        paths: p.scope.directoryPaths,
        records: workspaceLibraryRecords(p.scope.records, c),
      ),
      token: p.token,
      targetId: p.targetId,
      targetPath: p.targetPath,
      roots: p.roots,
      records: workspaceLibraryRecords(p.records, c),
      conflicts: p.conflicts,
      position: position,
      anchorName: p.anchorName,
    );
  });
  Future<WorkspaceLibraryMoveReceipt> move(
    WorkspaceLibraryMoveCommand command,
  ) => _run(() async {
    final receipt = _receipt(
      await owner.moveLibrarySelection(
        command.operationId,
        coreLibrarySelection(command.selection),
        command.targetId,
        command.reviewToken,
        position: _position(command.position),
      ),
    );
    changed();
    if (!receipt.matches(command)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与原移动不符，请核对结果。');
    }
    return receipt;
  }, writing: true);
  Future<WorkspaceLibraryMoveReceipt?> receipt(String id) => _run(() async {
    final receipt = await owner.libraryMoveReceipt(id);
    return receipt == null ? null : _receipt(receipt);
  });
}
