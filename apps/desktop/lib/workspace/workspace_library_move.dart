import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_library_recycle.dart';

class WorkspaceLibraryMovePreview {
  WorkspaceLibraryMovePreview({
    required this.scope,
    required this.token,
    required this.targetId,
    required Iterable<String> targetPath,
    required Iterable<String> roots,
    required Iterable<WorkspaceLibraryRecycleRecord> records,
    required Iterable<String> conflicts,
  }) : targetPath = List.unmodifiable(targetPath),
       roots = List.unmodifiable(roots),
       records = List.unmodifiable(records),
       conflicts = List.unmodifiable(conflicts);
  final WorkspaceLibraryRecyclePreview scope;
  final String token;
  final String? targetId;
  final List<String> targetPath, roots, conflicts;
  final List<WorkspaceLibraryRecycleRecord> records;
  bool get canSave => conflicts.isEmpty;
}

class WorkspaceLibraryMoveCommand {
  const WorkspaceLibraryMoveCommand({
    required this.operationId,
    required this.selection,
    required this.targetId,
    required this.reviewToken,
  });
  final String operationId, reviewToken;
  final WorkspaceLibrarySelection selection;
  final String? targetId;
  String get inputHash => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'action': 'move',
            'selection': selection.toJson(),
            'targetId': targetId,
            'reviewToken': reviewToken,
          }),
        ),
      )
      .toString();
}

class WorkspaceLibraryMoveReceipt {
  const WorkspaceLibraryMoveReceipt({
    required this.operationId,
    required this.inputHash,
    required this.targetId,
  });
  final String operationId, inputHash;
  final String? targetId;
  bool matches(WorkspaceLibraryMoveCommand command) =>
      operationId == command.operationId &&
      inputHash == command.inputHash &&
      targetId == command.targetId;
}

abstract interface class WorkspaceLibraryMove {
  bool get libraryMoveSupported;
  Future<WorkspaceLibraryMovePreview> previewLibraryMove(
    WorkspaceLibrarySelection selection,
    String? targetId,
  );
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  );
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(String id);
}
