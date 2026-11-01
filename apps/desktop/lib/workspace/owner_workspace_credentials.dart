import 'package:info_core/info_core.dart' as core;
import 'unavailable_workspace_sources.dart';
import 'workspace_source.dart';

/// Owner metadata projection only. Material bytes remain behind OwnerAccess;
/// writes and AI use are unavailable until their persistent adapters are wired.
class OwnerWorkspaceCredentials extends UnavailableWorkspaceCredential {
  OwnerWorkspaceCredentials(this.owner) : _scope = owner.captureLibraryScope();

  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;

  Future<T> _read<T>(T Function() action) async {
    try {
      return await owner.inLibraryScope(_scope, () async {
        if (!owner.serviceAvailable) {
          throw const WorkspaceFailure('unavailable', '凭据资料服务尚未就绪。');
        }
        return action();
      });
    } on core.AccessFailure catch (error) {
      if (error.status == 'library_changed') {
        throw const WorkspaceFailure('library_changed', '资料库已替换，请重新打开凭据。');
      }
      throw const WorkspaceFailure('unavailable', '凭据资料暂不可读取。');
    }
  }

  core.ManagedCredential _credential(WorkspaceRecordRef ref) {
    if (ref.kind != WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('invalid_reference', '此入口只读取托管凭据。');
    }
    final credential = owner.credentials
        .where((c) => c.id == ref.id)
        .firstOrNull;
    if (credential == null) {
      throw const WorkspaceFailure('not_found', '凭据已回收或不存在。');
    }
    return credential;
  }

  WorkspaceCredentialDetail _detail(core.ManagedCredential credential) {
    final file = credential.form == core.CredentialForm.file;
    final availability = owner.credentialAvailability(credential);
    return WorkspaceCredentialDetail(
      record: WorkspaceRecordSummary(
        ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
        name: credential.name,
        description: credential.publicPurpose,
        type: const WorkspaceType('credential', '凭据', 'key'),
        updatedAt: credential.modifiedAt,
      ),
      recordVersion: credential.revision,
      materialVersion: credential.version,
      useGeneration: credential.useGeneration,
      enabled: credential.enabled,
      useSupported: false,
      useUnavailableReason: availability == core.CredentialAvailability.expired
          ? '凭据已到期，不能批准新的使用。'
          : '新版凭据使用审批尚未接入，当前仅查看和核对原资料。',
      form: file
          ? WorkspaceCredentialForm.file
          : WorkspaceCredentialForm.string,
      format: file ? '凭据文件' : '凭据字符串',
      delivery: file
          ? WorkspaceCredentialDelivery.file
          : WorkspaceCredentialDelivery.environment,
      binding: credential.suggestedBinding,
      privateNote: credential.privateNote,
      filename: credential.fileName,
      linkedInformation: credential.linkedItemIds.map(
        (id) => WorkspaceRecordRef(WorkspaceRecordKind.information, id),
      ),
    );
  }

  @override
  Future<WorkspaceCredentialDetail> read(WorkspaceRecordRef ref) =>
      _read(() => _detail(_credential(ref)));

  @override
  Future<WorkspaceCredentialMaterialHistory> materials(
    WorkspaceRecordRef ref,
  ) => _read(() {
    final credential = _credential(ref);
    final file = credential.form == core.CredentialForm.file;
    final versions = owner.credentialVersions(credential.id)
      ..sort((a, b) => b.version.compareTo(a.version));
    return WorkspaceCredentialMaterialHistory(_detail(credential), [
      for (final version in versions)
        WorkspaceCredentialMaterial(
          version: version.version,
          form: file
              ? WorkspaceCredentialForm.file
              : WorkspaceCredentialForm.string,
          format: file ? '凭据文件' : '凭据字符串',
          filename: version.fileName,
          createdAt: version.createdAt,
          retiredAt: version.retiredAt,
        ),
    ]);
  });
}
