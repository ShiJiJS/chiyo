import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import 'library_widgets.dart';
import 'library_history_dialog.dart';
import 'library_file.dart';
import 'workspace_source.dart';

/// Explicit Owner read, separate from the content-free history queue.
class GrantHistoryContentDialog extends StatefulWidget {
  const GrantHistoryContentDialog({
    super.key,
    required this.source,
    required this.changes,
    required this.historyId,
    required this.record,
    required this.label,
    this.scopeId,
    this.inline = false,
  });
  final WorkspaceGrantHistorySource source;
  final Stream<WorkspaceRecordRef?> changes;
  final String historyId, label;
  final WorkspaceRecordRef record;
  final String? scopeId;
  final bool inline;
  @override
  State<GrantHistoryContentDialog> createState() =>
      _GrantHistoryContentDialogState();
}

class _GrantHistoryContentDialogState extends State<GrantHistoryContentDialog> {
  StreamSubscription<WorkspaceRecordRef?>? _subscription;
  WorkspaceArchive? _archive;
  WorkspaceFilePreview? _preview;
  WorkspaceFailure? _error;
  bool _loading = true;
  int _generation = 0, _page = 0;
  @override
  void initState() {
    super.initState();
    _subscription = widget.changes.listen((ref) {
      if (ref == null || ref == widget.record) {
        unawaited(_load(invalidate: true));
      }
    });
    unawaited(_load());
  }

  Future<void> _load({bool invalidate = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (invalidate) {
        _archive = null;
        _preview = null;
      }
    });
    try {
      final archive = widget.scopeId == null
          ? await widget.source.snapshot(widget.historyId, widget.record)
          : null;
      final preview = widget.scopeId != null
          ? await widget.source.filePreview(
              widget.historyId,
              widget.scopeId!,
              page: _page,
            )
          : null;
      if (mounted && generation == _generation) {
        setState(() {
          _archive = archive;
          _preview = preview;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '旧内容暂时无法读取。');
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Widget _body(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_loading) const LinearProgressIndicator(),
      if (_error != null)
        Text(_error!.message, style: libraryText(context, 14)),
      if (_archive != null) LibrarySnapshotView(archive: _archive!),
      if (_preview != null) ...[
        Text(
          '${_preview!.file.filename} · v${_preview!.file.ref.version}',
          style: libraryText(context, 14, weight: FontWeight.w600),
        ),
        LibraryFilePreviewView(
          preview: _preview!,
          onPage: (page) {
            if (_loading) return;
            _page = page;
            unawaited(_load());
          },
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => widget.inline
      ? _body(context)
      : DesktopDialog(
          title: Text(widget.label),
          content: _body(context),
          actions: [
            if (_error != null)
              DesktopButton(
                onPressed: _loading ? null : _load,
                child: const Text('重新读取'),
              ),
            DesktopButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
}
