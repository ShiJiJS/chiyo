part of 'sample_workspace_source.dart';

/// Additional in-memory interactions for the design prototype. No adapter,
/// database or server imports this class; restart restores the fixture.
class PreviewLibrarySource extends SampleWorkspaceSource
    implements
        WorkspaceLibraryRecycle,
        WorkspaceLibraryMove,
        WorkspaceStorageLocation {
  @override
  String get storageDescription => '已连接 · 家庭 NAS';
  PreviewLibrarySource({super.readAsset});
  final _recycleReceipts = <String, WorkspaceLibraryRecycleReceipt>{};
  final _moveReceipts = <String, WorkspaceLibraryMoveReceipt>{};
  final _reviewSelections = <String, WorkspaceLibraryRecyclePreview>{};
  WorkspaceSort _sort = WorkspaceSort.updated;
  @override
  bool get libraryRecycleSupported => true;
  @override
  bool get libraryMoveSupported => true;
  @override
  bool get libraryOrderSupported => false;
  @override
  WorkspaceSort get preferredLibrarySort => _sort;
  @override
  Future<void> saveLibrarySort(WorkspaceSort sort) async => _sort = sort;

  List<String> _path(String? id) {
    final result = <String>[];
    while (id != null) {
      final directory = _catalog.directories
          .where((d) => d.id == id)
          .firstOrNull;
      if (directory == null) break;
      result.insert(0, directory.name);
      id = directory.parentId;
    }
    return result;
  }

  @override
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycle(
    WorkspaceLibrarySelection selection,
  ) async {
    await _readable();
    final ids = selection.directoryIds.toSet();
    bool changed;
    do {
      changed = false;
      for (final d in _catalog.directories) {
        if (ids.contains(d.parentId) && ids.add(d.id)) changed = true;
      }
    } while (changed);
    final records = _records.values.where(
      (d) =>
          selection.records.contains(d.record.ref) ||
          ids.contains(d.record.directoryId),
    );
    final preview = WorkspaceLibraryRecyclePreview(
      token: workspaceOperationId(),
      roots: selection.directoryIds,
      directories: _catalog.directories.where((d) => ids.contains(d.id)),
      paths: {for (final id in ids) id: _path(id)},
      records: records.map(
        (d) => WorkspaceLibraryRecycleRecord(
          ref: d.record.ref,
          name: d.record.name,
          type: d.record.type.name,
          directoryId: d.record.directoryId,
          path: _path(d.record.directoryId),
        ),
      ),
    );
    _reviewSelections[preview.token] = preview;
    return preview;
  }

  @override
  Future<WorkspaceLibraryRecycleReceipt> changeLibraryRecycle(
    WorkspaceLibraryRecycleCommand command,
  ) async {
    final previous = _recycleReceipts[command.operationId];
    if (previous != null) return previous;
    final scope = _reviewSelections.remove(command.reviewToken);
    if (scope == null || command.restoring) {
      throw const WorkspaceFailure('expired', '请重新打开这次操作。');
    }
    for (final record in scope.records) {
      final detail = _records[record.ref];
      if (detail == null) continue;
      await changeRecord(
        WorkspaceRecordChange(
          operationId: workspaceOperationId(),
          ref: record.ref,
          expectedVersion: detail.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
    }
    final ids = scope.directories.map((d) => d.id).toSet();
    _catalog = WorkspaceCatalog(
      directories: _catalog.directories.where((d) => !ids.contains(d.id)),
      tags: _catalog.tags,
      types: _catalog.types,
      creatableTypes: _catalog.creatableTypes,
    );
    _catalogVersion++;
    _changes.add(null);
    return _recycleReceipts[command.operationId] =
        WorkspaceLibraryRecycleReceipt(
          operationId: command.operationId,
          inputHash: command.inputHash,
          batchId: command.operationId,
          restoring: false,
        );
  }

  @override
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycleRestore(
    String batchId,
    WorkspaceLibraryRestoreOptions options,
  ) async => throw const WorkspaceFailure('unsupported', '请在回收站逐条恢复资料。');
  @override
  Future<WorkspaceLibraryRecycleReceipt?> libraryRecycleOperationReceipt(
    String operationId,
  ) async => _recycleReceipts[operationId];

  @override
  Future<List<WorkspaceLibraryPlacementTarget>> libraryPlacementTargets(
    WorkspaceLibrarySelection selection,
  ) async => const [];
  @override
  Future<WorkspaceLibraryMovePreview> previewLibraryMove(
    WorkspaceLibrarySelection selection,
    String? targetId, {
    WorkspaceLibraryPosition? position,
  }) async {
    final scope = await previewLibraryRecycle(selection);
    return WorkspaceLibraryMovePreview(
      scope: scope,
      token: scope.token,
      targetId: targetId,
      targetPath: _path(targetId),
      roots: selection.directoryIds,
      records: scope.records,
      conflicts: scope.directories.any((d) => d.id == targetId)
          ? ['不能移入自身或自己的子目录。']
          : const [],
    );
  }

  @override
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  ) async {
    final previous = _moveReceipts[command.operationId];
    if (previous != null) return previous;
    final scope = _reviewSelections.remove(command.reviewToken);
    if (scope == null ||
        scope.directories.any((d) => d.id == command.targetId)) {
      throw const WorkspaceFailure('invalid', '请选择有效的目标目录。');
    }
    for (final ref in command.selection.records) {
      final detail = _records[ref];
      if (detail != null) {
        await saveRecord(
          WorkspaceEdit(
            values: const {},
            operationId: workspaceOperationId(),
            expectedVersion: detail.version,
            record: detail.record.copyWith(
              directoryId: command.targetId,
              unfiled: command.targetId == null,
            ),
          ),
        );
      }
    }
    _catalog = WorkspaceCatalog(
      directories: [
        for (final d in _catalog.directories)
          if (command.selection.directoryIds.contains(d.id))
            WorkspaceDirectory(d.id, d.name, parentId: command.targetId)
          else
            d,
      ],
      tags: _catalog.tags,
      types: _catalog.types,
      creatableTypes: _catalog.creatableTypes,
    );
    _catalogVersion++;
    _changes.add(null);
    return _moveReceipts[command.operationId] = WorkspaceLibraryMoveReceipt(
      operationId: command.operationId,
      inputHash: command.inputHash,
      targetId: command.targetId,
    );
  }

  @override
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(
    String id,
  ) async => _moveReceipts[id];
}
