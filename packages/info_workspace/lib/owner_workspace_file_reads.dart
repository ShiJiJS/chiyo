import 'package:info_core/info_core.dart' as core;
import 'owner_file_stages.dart';
import 'workspace_source.dart';

WorkspaceFileVersion workspaceFileVersion(
  core.InformationAttachmentVersion v,
) => WorkspaceFileVersion(
  ref: WorkspaceFileRef(
    v.reference.attachmentId,
    v.reference.attachmentVersion,
  ),
  filename: v.originalName,
  mediaType: v.mediaType,
  byteLength: v.byteLength,
  createdAt: v.createdAt,
  available: v.available,
  label: v.label,
  sourceNote: v.sourceNote,
);

/// Resolve the record's declared field before reading any attachment version.
/// This is shared by native and remote owner entry points, never Agent access.
class OwnerWorkspaceFileReads {
  OwnerWorkspaceFileReads(this.owner, this.information);
  final core.OwnerAccess owner;
  final OwnerFileInformation information;

  Future<({WorkspaceDetail detail, core.InformationAttachmentRef ref})> resolve(
    WorkspaceRecordRef record,
    String key,
  ) async {
    final detail = await information.readDetail(record);
    final fieldId = detail.fieldIds[key];
    final item = owner.information.where((i) => i.id == record.id).firstOrNull;
    final field = item?.fields.where((f) => f.id == fieldId).firstOrNull;
    if (record.kind != WorkspaceRecordKind.information ||
        field == null ||
        field.kind != core.FieldKind.file ||
        field.attachment == null) {
      throw const WorkspaceFailure('not_found', '此资料的文件字段已不可用。');
    }
    return (detail: detail, ref: field.attachment!);
  }

  Future<WorkspaceFileHistory> history(
    WorkspaceRecordRef record,
    String key,
  ) async {
    final resolved = await resolve(record, key);
    final versions = await owner.informationAttachmentVersions(
      resolved.ref.attachmentId,
    );
    final current = versions
        .where((v) => v.reference == resolved.ref)
        .firstOrNull;
    if (current == null) {
      throw const WorkspaceFailure('attachment_missing', '文件版本说明已不可用。');
    }
    return WorkspaceFileHistory(
      recordVersion: resolved.detail.version,
      current: workspaceFileVersion(current),
      versions:
          (versions.toList()..sort(
                (a, b) => b.reference.attachmentVersion.compareTo(
                  a.reference.attachmentVersion,
                ),
              ))
              .map(workspaceFileVersion),
    );
  }

  Future<core.OwnerInformationAttachment> read(
    WorkspaceRecordRef record,
    String key, {
    int? version,
  }) async {
    if (version != null && version < 1) {
      throw const WorkspaceFailure('invalid_request', '文件版本无效。');
    }
    final resolved = await resolve(record, key);
    return owner.readInformationAttachment(
      core.InformationAttachmentRef(
        resolved.ref.attachmentId,
        version ?? resolved.ref.attachmentVersion,
      ),
    );
  }
}
