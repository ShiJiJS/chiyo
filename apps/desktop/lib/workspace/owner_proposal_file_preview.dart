import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart' as core;
import '../desktop_controls.dart';
import 'library_file.dart';
import 'owner_proposal_original_reader.dart';
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
  late final _reader = OwnerProposalOriginalReader(
    widget.owner,
    pdf: widget.pdf,
  );
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
      final result = await _reader.read(
        widget.proposalId,
        widget.proposalVersion,
        widget.itemId,
        widget.attachmentKey,
        widget.version,
        page: page,
      );
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
          LibraryFilePreviewView(
            preview: _preview!,
            onPage: _load,
            unsupportedMessage: widget.version == 0
                ? '此文件格式暂不支持预览，可在资料库另存或用本机程序打开。'
                : '此格式暂不支持在App内预览；这份新原文尚未入库。',
          ),
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
