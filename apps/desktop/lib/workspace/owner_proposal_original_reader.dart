import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_files.dart';
import 'owner_pdf_preview.dart';
import 'workspace_source.dart';

/// Shared Owner reader for inline previews and the expanded original dialog.
/// Every read checks the library scope and exact proposal revision first.
class OwnerProposalOriginalReader {
  OwnerProposalOriginalReader(
    this.owner, {
    this.pdf = const NativeOwnerPdfPreview(),
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final OwnerPdfPreviewRenderer pdf;
  final core.OwnerLibraryScope _scope;
  Future<WorkspaceFilePreview> read(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    int page = 0,
  }) async {
    return owner.inLibraryScope(_scope, () async {
      final p = owner.importProposals
          .where((p) => p.id == proposalId)
          .firstOrNull;
      late core.OwnerImportOriginal content;
      if (p != null) {
        final item = p.items
            .where((i) => 'proposal:${p.id}:${i.key}' == itemId)
            .firstOrNull;
        if (item == null) throw const core.AccessFailure('proposal_changed');
        content = await owner.readImportOriginal(
          p.id,
          item.key,
          attachmentKey,
          version,
          proposalVersion: proposalVersion,
        );
      } else {
        final update = owner.updateProposals
            .where((p) => p.id == proposalId)
            .firstOrNull;
        if (update == null ||
            update.version != proposalVersion ||
            update.state != core.UpdateProposalState.pending ||
            update.input.itemId != itemId) {
          throw const core.AccessFailure('proposal_changed');
        }
        final attachment = update.input.attachments
            .where((a) => a.key == attachmentKey)
            .firstOrNull;
        if (attachment == null) {
          throw const core.AccessFailure('proposal_changed');
        }
        if (version == 0) {
          final previous =
              update.input.filePlan?.previousVersions[attachment.fieldId];
          if (previous == null) {
            throw const core.AccessFailure('proposal_changed');
          }
          return OwnerWorkspaceAttachmentPreview(
            owner,
            pdf: pdf,
          ).read(previous.reference, page: page);
        }
        content = await owner.readUpdateOriginal(
          update.id,
          proposalVersion,
          attachmentKey,
          version,
        );
      }
      final upload = content.upload;
      return OwnerWorkspaceAttachmentPreview(owner, pdf: pdf).renderContent(
        WorkspaceFileVersion(
          ref: WorkspaceFileRef(upload.id, version),
          filename: upload.originalName,
          mediaType: upload.mediaType,
          byteLength: upload.byteLength,
          createdAt: upload.createdAt,
          available: true,
        ),
        content.bytes,
        page: page,
      );
    });
  }
}
