import 'dart:async';
import 'package:flutter/material.dart';
import 'library_file.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

/// Exact retained attachment; a missing entry/version never falls back to the
/// current record. Reuses the same renderer and paging as ordinary files.
class RecycledAttachmentPreview extends StatefulWidget {
  const RecycledAttachmentPreview({
    super.key,
    required this.source,
    required this.entryId,
    required this.fieldKey,
  });
  final WorkspaceSource source;
  final String entryId, fieldKey;
  @override
  State<RecycledAttachmentPreview> createState() =>
      _RecycledAttachmentPreviewState();
}

class _RecycledAttachmentPreviewState extends State<RecycledAttachmentPreview> {
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  WorkspaceFilePreview? _preview;
  WorkspaceFailure? _failure;
  bool _loading = true;
  int _page = 0, _generation = 0;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _changes?.cancel();
    _changes = widget.source.changes.listen((_) => unawaited(_checkEntry()));
    unawaited(_load());
  }

  @override
  void didUpdateWidget(RecycledAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.entryId != widget.entryId ||
        oldWidget.fieldKey != widget.fieldKey) {
      _page = 0;
      _bind();
    }
  }

  Future<void> _checkEntry() async {
    final generation = _generation;
    try {
      final archive = await widget.source.readRecycled(widget.entryId);
      if (!mounted || generation != _generation) return;
      final ref = WorkspaceFileRef.fromJson(
        archive.detail.values[widget.fieldKey],
      );
      if (_preview?.file.ref == ref) return;
    } catch (_) {
      if (!mounted || generation != _generation) return;
    }
    // Unrelated updates do not fetch the attachment again. Missing or changed
    // entries clear the old preview and resolve the exact origin anew.
    await _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _preview = null;
      _failure = null;
    });
    try {
      final preview = await (widget.source as WorkspaceRecycledFiles)
          .readRecycledFilePreview(
            widget.entryId,
            widget.fieldKey,
            page: _page,
          );
      if (mounted && generation == _generation) {
        setState(() {
          _preview = preview;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _failure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '回收附件暂不可用，请重试。');
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_loading) const LinearProgressIndicator(),
      if (_failure != null) ...[
        Text(_failure!.message),
        TextButton(
          onPressed: _loading ? null : _load,
          child: const Text('重新读取附件'),
        ),
      ],
      if (_preview case final preview?) ...[
        Text(
          '${preview.file.filename} · 第 ${preview.file.ref.version} 版',
          style: libraryText(context, 14, weight: FontWeight.w600),
        ),
        LibraryFilePreviewView(
          preview: preview,
          onPage: (page) {
            if (!_loading) {
              _page = page;
              unawaited(_load());
            }
          },
        ),
      ],
    ],
  );
}
