import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/owner_proposal_original_contents.dart';
import 'owner_pdf_preview.dart';
import 'workspace_attachment_renderer.dart';
import 'workspace_source.dart';

/// Scope and revision checks are shared; native rendering stays on the device.
class OwnerProposalOriginalReader {
  OwnerProposalOriginalReader(
    this.owner, {
    this.pdf = const NativeOwnerPdfPreview(),
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final OwnerPdfPreviewRenderer pdf;
  final core.OwnerLibraryScope _scope;
  late final _contents = OwnerProposalOriginalContents(owner);
  Future<WorkspaceFilePreview> read(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    int page = 0,
  }) => owner.inLibraryScope(_scope, () async {
    final content = await _contents.pending(
      proposalId,
      proposalVersion,
      itemId,
      attachmentKey,
      version,
    );
    return WorkspaceAttachmentRenderer(
      pdf: pdf,
    ).renderContent(content.file, content.bytes, page: page);
  });
}
