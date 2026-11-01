import 'dart:convert';
import 'dart:ui' as ui;
import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_information.dart';
import 'workspace_source.dart';

/// Owner-only ordinary attachment reads. Page keys resolve through the current
/// record codec; callers cannot supply a free attachment ID or filesystem path.
class OwnerWorkspaceFiles {
  OwnerWorkspaceFiles(this.owner, this.information);
  final core.OwnerAccess owner;
  final OwnerWorkspaceInformation information;

  Future<({WorkspaceDetail detail, core.InformationAttachmentRef ref})>
  _resolve(WorkspaceRecordRef record, String key) async {
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

  WorkspaceFileVersion _version(core.InformationAttachmentVersion v) =>
      WorkspaceFileVersion(
        ref: WorkspaceFileRef(
          v.reference.attachmentId,
          v.reference.attachmentVersion,
        ),
        filename: v.originalName,
        mediaType: v.mediaType,
        byteLength: v.byteLength,
        createdAt: v.createdAt,
        available: v.available,
      );

  Future<WorkspaceFileHistory> history(
    WorkspaceRecordRef record,
    String key,
  ) async {
    final resolved = await _resolve(record, key);
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
      current: _version(current),
      versions:
          (versions.toList()..sort(
                (a, b) => b.reference.attachmentVersion.compareTo(
                  a.reference.attachmentVersion,
                ),
              ))
              .map(_version),
    );
  }

  Future<WorkspaceFilePreview> preview(
    WorkspaceRecordRef record,
    String key, {
    int? version,
    int page = 0,
  }) async {
    final resolved = await _resolve(record, key);
    if (page != 0 || (version != null && version < 1)) {
      throw const WorkspaceFailure('invalid_request', '页码或文件版本无效。');
    }
    final ref = core.InformationAttachmentRef(
      resolved.ref.attachmentId,
      version ?? resolved.ref.attachmentVersion,
    );
    try {
      final content = await owner.readInformationAttachment(ref);
      final file = _version(content.version);
      if (file.mediaType == 'text/plain') {
        return WorkspaceFilePreview(
          file: file,
          kind: WorkspaceFilePreviewKind.text,
          text: utf8.decode(content.bytes),
        );
      }
      if (!{'image/png', 'image/jpeg', 'image/webp'}.contains(file.mediaType)) {
        return WorkspaceFilePreview(
          file: file,
          kind: WorkspaceFilePreviewKind.unsupported,
        );
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(content.bytes);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? image;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width < 1 ||
            descriptor.height < 1 ||
            descriptor.width > 16384 ||
            descriptor.height > 16384 ||
            descriptor.width * descriptor.height > 16 * 1024 * 1024) {
          return WorkspaceFilePreview(
            file: file,
            kind: WorkspaceFilePreviewKind.unsupported,
          );
        }
        codec = await descriptor.instantiateCodec();
        image = (await codec.getNextFrame()).image;
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw const FormatException();
        return WorkspaceFilePreview(
          file: file,
          kind: WorkspaceFilePreviewKind.image,
          image: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          pixelWidth: image.width,
          pixelHeight: image.height,
        );
      } finally {
        image?.dispose();
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, switch (e.status) {
        'attachment_missing' => '该版本原文已清理或不可用，版本记录仍保留。',
        'service_unavailable' || 'library_changed' => '资料库已关闭或更换，请重新打开资料。',
        _ => '文件原文无法完整读取，请检查资料库后重试。',
      });
    } on Object {
      throw const WorkspaceFailure('preview_unavailable', '文件内容无法预览，未修改原文件。');
    }
  }
}
