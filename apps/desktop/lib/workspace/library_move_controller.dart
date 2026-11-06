import 'library_reviewed_operation_controller.dart';
import 'workspace_source.dart';

class LibraryMoveController
    extends
        LibraryReviewedOperationController<
          WorkspaceLibraryMovePreview,
          WorkspaceLibraryMoveCommand,
          WorkspaceLibraryMoveReceipt
        > {
  LibraryMoveController(
    super.source,
    this.selection, {
    this.targetId,
    this.position,
  });
  final WorkspaceLibrarySelection selection;
  String? targetId;
  WorkspaceLibraryPosition? position;
  WorkspaceLibraryMove get port => source as WorkspaceLibraryMove;
  Future<void> chooseTarget(String? id) async {
    if (frozen || reading) return;
    targetId = id;
    position = null;
    needsReview = true;
    await load();
  }

  @override
  Future<WorkspaceLibraryMovePreview> readPreview() =>
      port.previewLibraryMove(selection, targetId, position: position);
  @override
  bool previewAllowsSave(WorkspaceLibraryMovePreview preview) =>
      preview.canSave;
  @override
  WorkspaceLibraryMoveCommand createCommand(
    WorkspaceLibraryMovePreview preview,
  ) => WorkspaceLibraryMoveCommand(
    operationId: workspaceOperationId(),
    selection: selection,
    targetId: targetId,
    reviewToken: preview.token,
    position: position,
  );
  @override
  Future<WorkspaceLibraryMoveReceipt> commit(
    WorkspaceLibraryMoveCommand command,
  ) => port.moveLibrarySelection(command);
  @override
  Future<WorkspaceLibraryMoveReceipt?> lookup(String id) =>
      port.libraryMoveOperationReceipt(id);
  @override
  String operationId(WorkspaceLibraryMoveCommand command) =>
      command.operationId;
  @override
  bool matches(
    WorkspaceLibraryMoveReceipt receipt,
    WorkspaceLibraryMoveCommand command,
  ) => receipt.matches(command);
}
