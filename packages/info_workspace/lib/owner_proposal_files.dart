import 'package:info_core/info_core.dart' as core;
import 'workspace_files.dart';

/// Proposal scope and exact-revision checks remain in the shared adapter.
/// The desktop supplies native rendering; the server never opens an OS viewer.
abstract interface class OwnerProposalFiles {
  Future<WorkspaceFilePreview> pending(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    int page = 0,
  });
  Future<WorkspaceFilePreview> stored(
    core.InformationAttachmentRef reference, {
    int page = 0,
  });
}
