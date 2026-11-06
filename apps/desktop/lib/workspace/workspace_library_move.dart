import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_library_recycle.dart';
import 'workspace_records.dart';

class WorkspaceLibraryPosition {
  const WorkspaceLibraryPosition.directory(this.id, {this.after = false})
    : kind = 'directory';
  WorkspaceLibraryPosition.record(WorkspaceRecordRef ref, {this.after = false})
    : kind = ref.kind.name,
      id = ref.id;
  final String kind, id;
  final bool after;
  Map<String, Object?> toJson() => {
    'anchor': [kind, id],
    'after': after,
  };
}

class WorkspaceLibraryPlacement {
  const WorkspaceLibraryPlacement(this.directoryId, {this.position});
  final String? directoryId;
  final WorkspaceLibraryPosition? position;
}

class WorkspaceLibraryPlacementTarget {
  const WorkspaceLibraryPlacementTarget({
    required this.kind,
    required this.id,
    required this.name,
    required this.type,
    required this.path,
    required this.directoryId,
  });
  final String kind, id, name, type, path;
  final String? directoryId;
  WorkspaceLibraryPlacement placement({required bool after}) =>
      WorkspaceLibraryPlacement(
        directoryId,
        position: kind == 'directory'
            ? WorkspaceLibraryPosition.directory(id, after: after)
            : WorkspaceLibraryPosition.record(
                WorkspaceRecordRef(
                  kind == 'credential'
                      ? WorkspaceRecordKind.credential
                      : WorkspaceRecordKind.information,
                  id,
                ),
                after: after,
              ),
      );
}

class WorkspaceLibraryMovePreview {
  WorkspaceLibraryMovePreview({
    required this.scope,
    required this.token,
    required this.targetId,
    required Iterable<String> targetPath,
    required Iterable<String> roots,
    required Iterable<WorkspaceLibraryRecycleRecord> records,
    required Iterable<String> conflicts,
    this.position,
    this.anchorName,
  }) : targetPath = List.unmodifiable(targetPath),
       roots = List.unmodifiable(roots),
       records = List.unmodifiable(records),
       conflicts = List.unmodifiable(conflicts);
  final WorkspaceLibraryRecyclePreview scope;
  final String token;
  final String? targetId;
  final List<String> targetPath, roots, conflicts;
  final List<WorkspaceLibraryRecycleRecord> records;
  final WorkspaceLibraryPosition? position;
  final String? anchorName;
  bool get canSave => conflicts.isEmpty;
}

class WorkspaceLibraryMoveCommand {
  const WorkspaceLibraryMoveCommand({
    required this.operationId,
    required this.selection,
    required this.targetId,
    required this.reviewToken,
    this.position,
  });
  final String operationId, reviewToken;
  final WorkspaceLibrarySelection selection;
  final String? targetId;
  final WorkspaceLibraryPosition? position;
  String get inputHash => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'action': 'move',
            'selection': selection.toJson(),
            'targetId': targetId,
            'reviewToken': reviewToken,
            if (position != null) 'position': position!.toJson(),
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
  bool get libraryOrderSupported;
  WorkspaceSort? get preferredLibrarySort;
  Future<void> saveLibrarySort(WorkspaceSort sort);
  Future<List<WorkspaceLibraryPlacementTarget>> libraryPlacementTargets(
    WorkspaceLibrarySelection selection,
  );
  Future<WorkspaceLibraryMovePreview> previewLibraryMove(
    WorkspaceLibrarySelection selection,
    String? targetId, {
    WorkspaceLibraryPosition? position,
  });
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  );
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(String id);
}
