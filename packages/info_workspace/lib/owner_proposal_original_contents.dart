import 'package:info_core/info_core.dart' as core;
import 'file_transport.dart';
import 'owner_workspace_file_reads.dart';
import 'workspace_source.dart';

/// Shared Owner reader for inline previews and the expanded original dialog.
/// Every read checks the library scope and exact proposal revision first.
class OwnerProposalOriginalContents {
  OwnerProposalOriginalContents(this.owner)
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  Future<WorkspaceFileOriginal> pending(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version,
  ) async {
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
          return stored(previous.reference);
        }
        content = await owner.readUpdateOriginal(
          update.id,
          proposalVersion,
          attachmentKey,
          version,
        );
      }
      final upload = content.upload;
      return WorkspaceFileOriginal.verified(
        WorkspaceFileVersion(
          ref: WorkspaceFileRef(upload.id, version),
          filename: upload.originalName,
          mediaType: upload.mediaType,
          byteLength: upload.byteLength,
          createdAt: upload.createdAt,
          available: true,
        ),
        upload.sha256,
        content.bytes,
      );
    });
  }

  Future<WorkspaceFileOriginal> stored(
    core.InformationAttachmentRef reference,
  ) => owner.inLibraryScope(_scope, () async {
    final content = await owner.readInformationAttachment(reference);
    return WorkspaceFileOriginal.verified(
      workspaceFileVersion(content.version),
      content.version.sha256,
      content.bytes,
    );
  });
}
