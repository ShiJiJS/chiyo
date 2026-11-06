import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart' show StorageFailure;
import 'workspace_source.dart';

WorkspaceDirectoryRecycleBatch workspaceDirectoryRecycleBatch(
  core.LibraryRecycleBatch batch,
) {
  final ids = batch.directories.map((d) => d.id).toSet();
  return WorkspaceDirectoryRecycleBatch(
    id: batch.id,
    deletedAt: batch.deletedAt,
    expiresAt: batch.expiresAt,
    directoryCount: batch.directories.length,
    informationCount: batch.informationEntries.length,
    credentialCount: batch.credentialRevisions.length,
    names: batch.directories.isEmpty
        ? batch.records.map((r) => r.name)
        : batch.directories
              .where((d) => !ids.contains(d.parentId))
              .map((d) => (batch.directoryPaths[d.id] ?? [d.name]).join(' / ')),
  );
}

class OwnerWorkspaceLibraryRecycle {
  OwnerWorkspaceLibraryRecycle(this.owner, this.catalog, this.changed);
  final core.OwnerAccess owner;
  final Future<WorkspaceCatalog> Function() catalog;
  final void Function() changed;
  core.LibraryRecycleSelection _selection(
    WorkspaceLibrarySelection selection,
  ) => core.LibraryRecycleSelection(
    directoryIds: selection.directoryIds,
    informationIds: selection.records
        .where((r) => r.kind == WorkspaceRecordKind.information)
        .map((r) => r.id),
    credentialIds: selection.records
        .where((r) => r.kind == WorkspaceRecordKind.credential)
        .map((r) => r.id),
  );
  core.LibraryRecycleRestoreOptions _options(
    WorkspaceLibraryRestoreOptions options,
  ) => core.LibraryRecycleRestoreOptions(
    directoryNames: options.names,
    parentOverrides: options.parents,
  );
  WorkspaceLibraryRecycleReceipt _receipt(core.LibraryRecycleReceipt r) =>
      WorkspaceLibraryRecycleReceipt(
        operationId: r.operationId,
        inputHash: r.inputHash,
        batchId: r.batchId,
        restoring: r.action == core.LibraryRecycleAction.restore,
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
        'recycle_unavailable' => const WorkspaceFailure(
          'not_found',
          '这批内容已恢复、清理或到期。',
        ),
        'recycle_conflict' => const WorkspaceFailure(
          'conflict',
          '恢复范围存在冲突，请重新读取并调整。',
        ),
        'invalid_restoration_options' => const WorkspaceFailure(
          'validation',
          '请核对目录名称和恢复位置。',
        ),
        'operation_conflict' => const WorkspaceFailure(
          'operation_conflict',
          '原操作不能用于另一份决定。',
        ),
        _ => const WorkspaceFailure('unavailable', '暂时无法处理这批内容，请重新读取。'),
      };
    } on StorageFailure {
      throw const WorkspaceFailure('save_failed', '保存失败，原资料没有改变，可以重试。');
    } on WorkspaceFailure {
      rethrow;
    } catch (_) {
      throw WorkspaceFailure(
        writing ? 'unknown_outcome' : 'unavailable',
        writing ? '操作结果暂时无法确认，请先核对原操作。' : '暂时无法读取这批内容，请重试。',
      );
    }
  }

  List<WorkspaceLibraryRecycleRecord> _records(
    Iterable<core.LibraryRecycleRecord> records,
    WorkspaceCatalog catalog,
  ) => [
    for (final r in records)
      WorkspaceLibraryRecycleRecord(
        ref: WorkspaceRecordRef(
          r.kind == 'credential'
              ? WorkspaceRecordKind.credential
              : WorkspaceRecordKind.information,
          r.id,
        ),
        name: r.name,
        type:
            catalog.types.where((t) => t.id == r.typeId).firstOrNull?.name ??
            (r.kind == 'credential' ? '凭据' : '资料'),
        directoryId: r.directoryId,
        path: r.directoryPath,
      ),
  ];
  Future<WorkspaceLibraryRecyclePreview> preview(
    WorkspaceLibrarySelection selection,
  ) => _run(() async {
    final c = await catalog(),
        p = await owner.previewLibraryRecycle(_selection(selection));
    return WorkspaceLibraryRecyclePreview(
      token: p.token,
      directories: p.directories.map(
        (d) => WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
      ),
      paths: p.directoryPaths,
      records: _records(p.records, c),
    );
  });
  Future<WorkspaceLibraryRecyclePreview> restorePreview(
    String id,
    WorkspaceLibraryRestoreOptions options,
  ) => _run(() async {
    final c = await catalog(),
        p = await owner.previewLibraryRecycleRestore(
          id,
          options: _options(options),
        );
    final batch = owner.libraryRecycleBatches.singleWhere((b) => b.id == id),
        ids = batch.directories.map((d) => d.id).toSet();
    return WorkspaceLibraryRecyclePreview(
      token: p.token,
      directories: p.directories.map(
        (d) => WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
      ),
      paths: p.directoryPaths,
      records: _records(p.records, c),
      roots: batch.directories
          .where((d) => !ids.contains(d.parentId))
          .map((d) => d.id),
      warnings: p.warnings,
      conflicts: p.conflicts,
    );
  });
  Future<WorkspaceLibraryRecycleReceipt> change(
    WorkspaceLibraryRecycleCommand c,
  ) => _run(() async {
    final r = c.restoring
        ? await owner.restoreLibraryRecycleBatch(
            c.operationId,
            c.batchId!,
            c.reviewToken,
            options: _options(c.options),
          )
        : await owner.recycleLibrarySelection(
            c.operationId,
            _selection(c.selection!),
            c.reviewToken,
          );
    changed();
    final result = _receipt(r);
    if (!result.matches(c)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与原操作不符，请核对结果。');
    }
    return result;
  }, writing: true);
  Future<WorkspaceLibraryRecycleReceipt?> receipt(String id) => _run(() async {
    final r = await owner.libraryRecycleReceipt(id);
    return r == null ? null : _receipt(r);
  });
}
