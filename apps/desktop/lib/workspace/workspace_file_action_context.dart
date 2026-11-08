import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/owner_workspace_file_reads.dart';
import 'owner_workspace_files.dart';
import 'owner_workspace_information.dart';
import 'workspace_source.dart';

/// Data and lifetime seam for the existing local publication/open workflow.
/// Remote clients fetch verified originals; the native adapter keeps its owner
/// snapshot barrier. Native output paths never cross this seam or the network.
abstract interface class WorkspaceFileActionContext {
  bool get isCurrent;
  void check();
  Future<T> run<T>(Future<T> Function() action);
  Future<WorkspaceDetail> detail(WorkspaceRecordRef record);
  Future<WorkspaceFileHistory> history(WorkspaceRecordRef record, String key);
  Future<WorkspaceFileOriginal> original(
    WorkspaceRecordRef record,
    String key,
    core.InformationAttachmentRef reference,
  );
  Future<void> assertCurrent(
    WorkspaceRecordRef record,
    String key,
    String? fieldId,
    core.InformationAttachmentRef reference,
  );
}

class OwnerFileActionContext implements WorkspaceFileActionContext {
  OwnerFileActionContext(this.owner, this.information, this.files)
    : scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope scope;
  final OwnerWorkspaceInformation information;
  final OwnerWorkspaceFiles files;
  @override
  bool get isCurrent => scope.isCurrent && owner.serviceAvailable;
  @override
  void check() {
    if (!isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料库已关闭或更换，请重新打开文件。');
    }
  }

  @override
  Future<T> run<T>(Future<T> Function() action) => owner.exportLibrary(action);
  @override
  Future<WorkspaceDetail> detail(WorkspaceRecordRef record) =>
      information.readDetail(record);
  @override
  Future<WorkspaceFileHistory> history(WorkspaceRecordRef record, String key) =>
      files.history(record, key);
  @override
  Future<WorkspaceFileOriginal> original(
    WorkspaceRecordRef record,
    String key,
    core.InformationAttachmentRef reference,
  ) async {
    final body = await owner.readInformationAttachment(reference);
    return WorkspaceFileOriginal.verified(
      workspaceFileVersion(body.version),
      body.version.sha256,
      body.bytes,
    );
  }

  @override
  Future<void> assertCurrent(
    WorkspaceRecordRef record,
    String key,
    String? fieldId,
    core.InformationAttachmentRef reference,
  ) async {
    final field = owner.information
        .where((i) => i.id == record.id)
        .firstOrNull
        ?.fields
        .where((f) => f.id == fieldId)
        .firstOrNull;
    if (field?.attachment != reference) {
      throw const WorkspaceFailure('conflict', '文件已变化，请重新核对。');
    }
  }
}
