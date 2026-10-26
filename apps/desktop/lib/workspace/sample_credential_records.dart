import 'workspace_records.dart';
import 'workspace_history.dart';
import 'workspace_credentials.dart';

typedef SampleCredentialRecycleRecord = ({
  WorkspaceRecycleEntry entry,
  WorkspaceArchive archive,
});
typedef SampleCredentialRestoreRecord = ({
  WorkspaceDetail detail,
  List<String> notices,
});

/// Composition seam between the independent fictional credential vault and
/// shared classification/relations/recycle projections. Never contains material.
abstract interface class SampleCredentialRecordStore {
  int get credentialCatalogVersion;
  WorkspaceDetail currentCredentialRecord(WorkspaceRecordRef ref);
  WorkspaceDetail prepareCredentialRecord(
    WorkspaceRecordRef ref,
    WorkspaceCredentialWrite? write,
  );
  void commitCredentialRecord(WorkspaceDetail detail);
  SampleCredentialRecycleRecord? recycledCredentialRecord(String entryId);
  WorkspaceRecycleEntry recycleCredentialRecord(
    WorkspaceRecordRef ref,
    int version,
  );
  SampleCredentialRestoreRecord prepareCredentialRestore(
    String entryId,
    int version,
  );
  void commitCredentialRestore(String entryId, WorkspaceDetail detail);
  void purgeCredentialRecord(String entryId);
}
