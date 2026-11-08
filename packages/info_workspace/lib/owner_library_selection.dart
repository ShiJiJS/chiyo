import 'package:info_core/info_core.dart' as core;
import 'workspace_source.dart';

core.LibrarySelection coreLibrarySelection(
  WorkspaceLibrarySelection selection,
) => core.LibrarySelection(
  directoryIds: selection.directoryIds,
  informationIds: selection.records
      .where((r) => r.kind == WorkspaceRecordKind.information)
      .map((r) => r.id),
  credentialIds: selection.records
      .where((r) => r.kind == WorkspaceRecordKind.credential)
      .map((r) => r.id),
);

List<WorkspaceLibraryRecycleRecord> workspaceLibraryRecords(
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
