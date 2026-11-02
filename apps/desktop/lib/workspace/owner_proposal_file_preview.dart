import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart' as core;
import '../desktop_controls.dart';
import 'library_file.dart';
import 'owner_workspace_files.dart';
import 'owner_pdf_preview.dart';
import 'workspace_source.dart';

Future<void> showOwnerProposalFilePreview(
  BuildContext context,
  core.OwnerAccess owner,
  String proposalId,
  int proposalVersion,
  String itemId,
  String attachmentKey,
  int version, {
  OwnerPdfPreviewRenderer pdf = const NativeOwnerPdfPreview(),
}) => showDesktopDialog<void>(
  context,
  builder: (_) => _Original(
    owner,
    proposalId,
    proposalVersion,
    itemId,
    attachmentKey,
    version,
    pdf,
  ),
);

class _Original extends StatefulWidget {
  const _Original(
    this.owner,
    this.proposalId,
    this.proposalVersion,
    this.itemId,
    this.attachmentKey,
    this.version,
    this.pdf,
  );
  final core.OwnerAccess owner;
  final String proposalId, itemId, attachmentKey;
  final int proposalVersion, version;
  final OwnerPdfPreviewRenderer pdf;
  @override
  State<_Original> createState() => _OriginalState();
}

class _OriginalState extends State<_Original> {
  late final _scope = widget.owner.captureLibraryScope();
  WorkspaceFilePreview? _preview;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load(0);
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load(int page) async {
    final generation = ++_generation;
    setState(() {
      _preview = null;
      _error = null;
    });
    try {
      final result = await widget.owner.inLibraryScope(_scope, () async {
        final p = widget.owner.importProposals
            .where((p) => p.id == widget.proposalId)
            .firstOrNull;
        final item = p?.items
            .where((i) => 'proposal:${p.id}:${i.key}' == widget.itemId)
            .firstOrNull;
        if (p == null || item == null) {
          throw const core.AccessFailure('proposal_changed');
        }
        final content = await widget.owner.readImportOriginal(
          p.id,
          item.key,
          widget.attachmentKey,
          widget.version,
          proposalVersion: widget.proposalVersion,
        );
        final upload = content.upload;
        return OwnerWorkspaceAttachmentPreview(
          widget.owner,
          pdf: widget.pdf,
        ).renderContent(
          WorkspaceFileVersion(
            ref: WorkspaceFileRef(upload.id, widget.version),
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
      if (mounted && generation == _generation) {
        setState(() => _preview = result);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is WorkspaceFailure
              ? error.message
              : '提案已变化或原文暂时不可用，请关闭后重新核对。',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('核对待录入原文'),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('只核对原文，关闭后再决定是否批准入库。'),
        const SizedBox(height: 12),
        if (_error != null)
          Text(_error!)
        else if (_preview == null)
          const LinearProgressIndicator()
        else
          LibraryFilePreviewView(preview: _preview!, onPage: _load),
      ],
    ),
    actions: [
      DesktopButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
