import 'package:info_workspace/owner_workspace_file_reads.dart';
import 'workspace_attachment_renderer.dart';
import 'dart:typed_data';
import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_information.dart';
import 'owner_pdf_preview.dart';
import 'workspace_source.dart';

/// Owner-only ordinary attachment reads. Page keys resolve through the current
/// record codec; callers cannot supply a free attachment ID or filesystem path.
class OwnerWorkspaceFiles {
  OwnerWorkspaceFiles(
    this.owner,
    this.information, {
    this.pdf = const NativeOwnerPdfPreview(),
  });
  final OwnerPdfPreviewRenderer pdf;
  final core.OwnerAccess owner;
  final OwnerWorkspaceInformation information;

  late final _reads = OwnerWorkspaceFileReads(owner, information);
  Future<WorkspaceFileHistory> history(WorkspaceRecordRef record, String key) =>
      _reads.history(record, key);

  Future<WorkspaceFilePreview> preview(
    WorkspaceRecordRef record,
    String key, {
    int? version,
    WorkspaceFileRef? exact,
    int page = 0,
  }) async {
    if (page < 0 || (version != null && version < 1)) {
      throw const WorkspaceFailure('invalid_request', '页码或文件版本无效。');
    }
    final ref = await _reads.reference(
      record,
      key,
      version: version,
      exact: exact,
    );
    return OwnerWorkspaceAttachmentPreview(
      owner,
      pdf: pdf,
    ).read(ref, page: page);
  }
}

/// Shared Owner renderer. Callers resolve and validate a current field or exact
/// historical attachment reference before entering this content read.
class OwnerWorkspaceAttachmentPreview {
  const OwnerWorkspaceAttachmentPreview(
    this.owner, {
    this.pdf = const NativeOwnerPdfPreview(),
  });
  final core.OwnerAccess owner;
  final OwnerPdfPreviewRenderer pdf;

  Future<WorkspaceFilePreview> read(
    core.InformationAttachmentRef ref, {
    int page = 0,
  }) => _read(ref, page: page);

  Future<WorkspaceFilePreview> delivered(
    core.InformationFileDelivery delivery, {
    int page = 0,
  }) => _read(delivery.attachment, page: page, original: delivery);

  /// Trusted Owner originals already checked by their source. No file paths.
  Future<WorkspaceFilePreview> renderContent(
    WorkspaceFileVersion file,
    Uint8List bytes, {
    int page = 0,
  }) => WorkspaceAttachmentRenderer(
    pdf: pdf,
  ).renderContent(file, bytes, page: page);

  Future<WorkspaceFilePreview> _read(
    core.InformationAttachmentRef ref, {
    int page = 0,
    core.InformationFileDelivery? original,
  }) async {
    if (page < 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
    try {
      final content = await owner.readInformationAttachment(ref);
      final v = content.version;
      if (original != null &&
          (v.reference != original.attachment ||
              v.sha256 != original.sha256 ||
              v.byteLength != original.byteLength ||
              v.originalName != original.fileName ||
              v.mediaType != original.mediaType)) {
        throw const core.AccessFailure('attachment_integrity_failed');
      }
      final file = WorkspaceFileVersion(
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
      return await renderContent(file, content.bytes, page: page);
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, switch (e.status) {
        'attachment_missing' => '该版本原文已清理或不可用，版本记录仍保留。',
        'service_unavailable' || 'library_changed' => '资料库已关闭或更换，请重新打开资料。',
        _ => '文件原文无法完整读取，请检查资料库后重试。',
      });
    } on WorkspaceFailure {
      rethrow;
    } on Object {
      throw const WorkspaceFailure('preview_unavailable', '文件内容无法预览，未修改原文件。');
    }
  }
}
