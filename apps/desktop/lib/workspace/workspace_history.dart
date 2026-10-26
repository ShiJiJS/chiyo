import 'workspace_records.dart';

/// Immutable owner snapshot. Lists expose only [WorkspaceRevision] metadata;
/// content and historical identity labels are requested explicitly.
class WorkspaceArchive {
  WorkspaceArchive({
    required this.detail,
    required this.archivedAt,
    this.directoryName,
    Map<WorkspaceRecordRef, WorkspaceRecordSummary> targets = const {},
  }) : targets = Map.unmodifiable(targets);
  final WorkspaceDetail detail;
  final DateTime archivedAt;
  final String? directoryName;
  final Map<WorkspaceRecordRef, WorkspaceRecordSummary> targets;
}

class WorkspaceRevision {
  const WorkspaceRevision(this.record, this.version, this.archivedAt);
  final WorkspaceRecordSummary record;
  final int version;
  final DateTime archivedAt;
}

class WorkspaceRevisionPreview {
  WorkspaceRevisionPreview({
    required this.current,
    required this.archive,
    required this.restored,
    required this.catalogVersion,
    Iterable<String> notices = const [],
    Iterable<String> missingFields = const [],
  }) : notices = List.unmodifiable(notices),
       missingFields = List.unmodifiable(missingFields);
  final WorkspaceDetail current, restored;
  final WorkspaceArchive archive;
  final int catalogVersion;
  final List<String> notices, missingFields;
  bool get canRestore => missingFields.isEmpty;
}

class WorkspaceRecycleEntry {
  const WorkspaceRecycleEntry({
    required this.id,
    required this.record,
    required this.version,
    required this.deletedAt,
    required this.expiresAt,
    this.directoryName,
  });
  final String id;
  final WorkspaceRecordSummary record;
  final int version;
  final DateTime deletedAt, expiresAt;
  final String? directoryName;
}

class WorkspaceRecycleResults {
  WorkspaceRecycleResults({
    required Iterable<WorkspaceRecycleEntry> items,
    required this.total,
    required this.offset,
  }) : items = List.unmodifiable(items);
  final List<WorkspaceRecycleEntry> items;
  final int total, offset;
}

enum WorkspaceRecordAction { recycle, restoreRevision, restoreRecycled, purge }

class WorkspaceRecordChange {
  const WorkspaceRecordChange({
    required this.operationId,
    required this.ref,
    required this.expectedVersion,
    required this.action,
    this.revisionVersion,
    this.entryId,
    this.expectedCatalogVersion,
  });
  final String operationId;
  final WorkspaceRecordRef ref;
  final int expectedVersion;
  final WorkspaceRecordAction action;
  final int? revisionVersion, expectedCatalogVersion;
  final String? entryId;
}

/// Content-free operation receipt; source adapters must not cache erased body
/// values in idempotency records after permanent deletion.
class WorkspaceRecordReceipt {
  WorkspaceRecordReceipt({
    required this.ref,
    required this.version,
    this.entryId,
    Iterable<String> notices = const [],
  }) : notices = List.unmodifiable(notices);
  final WorkspaceRecordRef ref;
  final int version;
  final String? entryId;
  final List<String> notices;
}
