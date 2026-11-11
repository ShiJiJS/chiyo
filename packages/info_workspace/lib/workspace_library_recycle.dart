import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';

class WorkspaceLibrarySelection {
  WorkspaceLibrarySelection({
    Iterable<String> directoryIds = const [],
    Iterable<WorkspaceRecordRef> records = const [],
  }) : directoryIds = List.unmodifiable(directoryIds.toSet().toList()..sort()),
       records = List.unmodifiable(records.toSet());
  final List<String> directoryIds;
  final List<WorkspaceRecordRef> records;
  Map<String, Object?> toJson() => {
    'directories': directoryIds,
    'information':
        records
            .where((r) => r.kind == WorkspaceRecordKind.information)
            .map((r) => r.id)
            .toList()
          ..sort(),
    'credentials':
        records
            .where((r) => r.kind == WorkspaceRecordKind.credential)
            .map((r) => r.id)
            .toList()
          ..sort(),
  };
}

class WorkspaceLibraryRestoreOptions {
  WorkspaceLibraryRestoreOptions({
    Map<String, String> names = const {},
    Map<String, String?> parents = const {},
  }) : names = Map.unmodifiable(names),
       parents = Map.unmodifiable(parents);
  final Map<String, String> names;
  final Map<String, String?> parents;
  Map<String, Object?> toJson() => {
    'names': {for (final id in names.keys.toList()..sort()) id: names[id]},
    'parents': {
      for (final id in parents.keys.toList()..sort()) id: parents[id],
    },
  };
}

class WorkspaceLibraryRecycleRecord {
  WorkspaceLibraryRecycleRecord({
    required this.ref,
    required this.name,
    required this.type,
    required this.directoryId,
    required Iterable<String> path,
    this.recycleEntryId,
  }) : path = List.unmodifiable(path);
  final WorkspaceRecordRef ref;
  final String name, type;
  final String? directoryId;

  /// Read-only retained origin, supplied only for a restore preview. Mutations
  /// still target the whole batch and never this individual member.
  final String? recycleEntryId;
  final List<String> path;
}

class WorkspaceLibraryRecyclePreview {
  WorkspaceLibraryRecyclePreview({
    required this.token,
    required Iterable<WorkspaceDirectory> directories,
    required Map<String, List<String>> paths,
    required Iterable<WorkspaceLibraryRecycleRecord> records,
    Iterable<String> roots = const [],
    Iterable<String> warnings = const [],
    Iterable<String> conflicts = const [],
  }) : directories = List.unmodifiable(directories),
       paths = Map.unmodifiable({
         for (final e in paths.entries)
           e.key: List<String>.unmodifiable(e.value),
       }),
       records = List.unmodifiable(records),
       roots = List.unmodifiable(roots),
       warnings = List.unmodifiable(warnings),
       conflicts = List.unmodifiable(conflicts);
  final String token;
  final List<WorkspaceDirectory> directories;
  final Map<String, List<String>> paths;
  final List<WorkspaceLibraryRecycleRecord> records;
  final List<String> roots, warnings, conflicts;
  int get informationCount => records
      .where((r) => r.ref.kind == WorkspaceRecordKind.information)
      .length;
  int get credentialCount =>
      records.where((r) => r.ref.kind == WorkspaceRecordKind.credential).length;
  bool get canSave => conflicts.isEmpty;
}

class WorkspaceLibraryRecycleCommand {
  WorkspaceLibraryRecycleCommand({
    required this.operationId,
    required this.reviewToken,
    this.selection,
    this.batchId,
    WorkspaceLibraryRestoreOptions? options,
  }) : options = options ?? WorkspaceLibraryRestoreOptions();
  final String operationId, reviewToken;
  final WorkspaceLibrarySelection? selection;
  final String? batchId;
  final WorkspaceLibraryRestoreOptions options;
  bool get restoring => batchId != null;
  String get inputHash => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            restoring
                ? {
                    'action': 'restore',
                    'batchId': batchId,
                    'reviewToken': reviewToken,
                    'options': options.toJson(),
                  }
                : {
                    'action': 'recycle',
                    'selection': selection!.toJson(),
                    'reviewToken': reviewToken,
                  },
          ),
        ),
      )
      .toString();
}

class WorkspaceLibraryRecycleReceipt {
  const WorkspaceLibraryRecycleReceipt({
    required this.operationId,
    required this.inputHash,
    required this.batchId,
    required this.restoring,
  });
  final String operationId, inputHash, batchId;
  final bool restoring;
  bool matches(WorkspaceLibraryRecycleCommand c) =>
      operationId == c.operationId &&
      inputHash == c.inputHash &&
      restoring == c.restoring &&
      (!restoring || batchId == c.batchId);
}

class WorkspaceDirectoryRecycleBatch {
  WorkspaceDirectoryRecycleBatch({
    required this.id,
    required this.deletedAt,
    required this.expiresAt,
    required this.directoryCount,
    required this.informationCount,
    required this.credentialCount,
    required Iterable<String> names,
  }) : names = List.unmodifiable(names);
  final String id;
  final DateTime deletedAt, expiresAt;
  final int directoryCount, informationCount, credentialCount;
  final List<String> names;
  String get title => names.isEmpty
      ? '一批资料'
      : names.take(3).join('、') + (names.length > 3 ? '等' : '');
  String get counts =>
      '$directoryCount 个目录、$informationCount 条资料、$credentialCount 项凭据';
}

abstract interface class WorkspaceLibraryRecycle {
  bool get libraryRecycleSupported;
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycle(
    WorkspaceLibrarySelection selection,
  );
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycleRestore(
    String batchId,
    WorkspaceLibraryRestoreOptions options,
  );
  Future<WorkspaceLibraryRecycleReceipt> changeLibraryRecycle(
    WorkspaceLibraryRecycleCommand command,
  );
  Future<WorkspaceLibraryRecycleReceipt?> libraryRecycleOperationReceipt(
    String operationId,
  );
}
