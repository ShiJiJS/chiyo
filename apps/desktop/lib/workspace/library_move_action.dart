import 'package:flutter/material.dart';
import 'library_move_controller.dart';
import 'library_move_dialog.dart';
import 'workspace_source.dart';

/// A drop or an explicit before/after choice is the owner action. Save once;
/// if its outcome is uncertain, keep the same controller and frozen command
/// in the common recovery window rather than manufacturing a second move.
Future<WorkspaceLibraryMoveReceipt?> performLibraryPlacement(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceLibrarySelection selection,
  WorkspaceLibraryPlacement placement,
) async {
  final controller = LibraryMoveController(
    source,
    selection,
    targetId: placement.directoryId,
    position: placement.position,
  );
  try {
    await controller.load();
    if (controller.canSave) await controller.save();
    if (controller.receipt != null) return controller.receipt;
    if (!context.mounted) return null;
    return await showLibraryMove(
      context,
      source,
      selection,
      controller: controller,
    );
  } finally {
    controller.dispose();
  }
}
