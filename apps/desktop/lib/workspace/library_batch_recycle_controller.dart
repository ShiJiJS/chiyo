import 'library_reviewed_operation_controller.dart';
import 'workspace_source.dart';

class LibraryBatchRecycleController
    extends
        LibraryReviewedOperationController<
          WorkspaceLibraryRecyclePreview,
          WorkspaceLibraryRecycleCommand,
          WorkspaceLibraryRecycleReceipt
        > {
  LibraryBatchRecycleController(super.source, {this.selection, this.batchId});
  final WorkspaceLibrarySelection? selection;
  final String? batchId;
  WorkspaceLibraryRecycle get port => source as WorkspaceLibraryRecycle;
  bool get restoring => batchId != null;
  WorkspaceLibraryRestoreOptions options = WorkspaceLibraryRestoreOptions();
  void rename(String id, String name) {
    if (frozen || reading) return;
    options = WorkspaceLibraryRestoreOptions(
      names: {...options.names, id: name},
      parents: options.parents,
    );
    needsReview = true;
    failure = null;
    notice = null;
    notifyListeners();
  }

  Future<void> moveRoot(String id, String? parent) async {
    if (frozen || reading) return;
    options = WorkspaceLibraryRestoreOptions(
      names: options.names,
      parents: {...options.parents, id: parent},
    );
    needsReview = true;
    await load();
  }

  @override
  Future<WorkspaceLibraryRecyclePreview> readPreview() => restoring
      ? port.previewLibraryRecycleRestore(batchId!, options)
      : port.previewLibraryRecycle(selection!);
  @override
  bool previewAllowsSave(WorkspaceLibraryRecyclePreview preview) =>
      preview.canSave;
  @override
  WorkspaceLibraryRecycleCommand createCommand(
    WorkspaceLibraryRecyclePreview preview,
  ) => WorkspaceLibraryRecycleCommand(
    operationId: workspaceOperationId(),
    reviewToken: preview.token,
    selection: selection,
    batchId: batchId,
    options: options,
  );
  @override
  Future<WorkspaceLibraryRecycleReceipt> commit(
    WorkspaceLibraryRecycleCommand command,
  ) => port.changeLibraryRecycle(command);
  @override
  Future<WorkspaceLibraryRecycleReceipt?> lookup(String id) =>
      port.libraryRecycleOperationReceipt(id);
  @override
  String operationId(WorkspaceLibraryRecycleCommand command) =>
      command.operationId;
  @override
  bool matches(
    WorkspaceLibraryRecycleReceipt receipt,
    WorkspaceLibraryRecycleCommand command,
  ) => receipt.matches(command);
}
