import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/owner_proposal_files.dart';
import 'package:info_workspace/owner_workspace_proposals.dart' as shared;
import 'owner_proposal_original_reader.dart';
import 'owner_workspace_files.dart';
import 'workspace_source.dart';

/// Both hosts use the same review, whole-proposal admission and receipt rules.
/// Only local file rendering is supplied by this desktop wrapper.
class OwnerWorkspaceProposals extends shared.OwnerWorkspaceProposals {
  OwnerWorkspaceProposals({
    required super.owner,
    required super.library,
    required super.changed,
  }) : super(originals: _DesktopProposalFiles(owner));
}

class _DesktopProposalFiles implements OwnerProposalFiles {
  _DesktopProposalFiles(this.owner);
  final core.OwnerAccess owner;
  late final _pending = OwnerProposalOriginalReader(owner);
  late final _stored = OwnerWorkspaceAttachmentPreview(owner);
  @override
  Future<WorkspaceFilePreview> pending(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    int page = 0,
  }) => _pending.read(
    proposalId,
    proposalVersion,
    itemId,
    attachmentKey,
    version,
    page: page,
  );
  @override
  Future<WorkspaceFilePreview> stored(
    core.InformationAttachmentRef reference, {
    int page = 0,
  }) => _stored.read(reference, page: page);
}
