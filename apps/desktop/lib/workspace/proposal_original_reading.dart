import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import 'library_file.dart';
import 'library_file_dialogs.dart';
import 'workspace_source.dart';
import 'proposal_reading_state.dart';

/// Read-only original content, using the same reader as the information library.
class ProposalOriginalReading extends StatefulWidget {
  const ProposalOriginalReading({
    super.key,
    required this.load,
    this.enabled = true,
    this.readingState,
  });
  final Future<WorkspaceFilePreview> Function(int page) load;
  final bool enabled;
  final ProposalReadingState? readingState;
  @override
  State<ProposalOriginalReading> createState() =>
      _ProposalOriginalReadingState();
}

class _ProposalOriginalReadingState extends State<ProposalOriginalReading> {
  Future<WorkspaceFilePreview>? _content;
  Future<WorkspaceFilePreview> _read(int page) {
    final future = widget.load(page);
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _content = _read(widget.readingState?.page ?? 0);
  }

  @override
  void didUpdateWidget(covariant ProposalOriginalReading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _content = widget.enabled ? _read(0) : null;
    }
  }

  void _page(int page) {
    if (widget.enabled) {
      widget.readingState?.page = page;
      setState(() {
        _content = _read(page);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const Text('请先重新核对提案，再读取原文。');
    return FutureBuilder<WorkspaceFilePreview>(
      future: _content,
      builder: (context, result) {
        if (result.connectionState != ConnectionState.done) {
          return const LinearProgressIndicator();
        }
        if (result.hasError) {
          final error = result.error;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(error is WorkspaceFailure ? error.message : '原文暂时无法读取。'),
              const SizedBox(height: 8),
              DesktopButton(
                onPressed: () => _page(0),
                child: const Text('重新读取原文'),
              ),
            ],
          );
        }
        final preview = result.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LibraryFileSummary(
              label: '文件',
              filename: preview.file.filename,
              mediaType: preview.file.mediaType,
              byteLength: preview.file.byteLength,
            ),
            const SizedBox(height: 12),
            LibraryFilePreviewView(
              preview: preview,
              onPage: _page,
              unsupportedMessage: '此文件格式暂不支持在App内预览。',
            ),
          ],
        );
      },
    );
  }
}
