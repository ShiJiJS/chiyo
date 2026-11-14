import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'proposal_reading.dart';
import 'workspace_source.dart';
import 'proposal_reading_state.dart';
import 'workspace_refresh.dart';

/// Loads exact Owner-only content in place. No library route or management
/// action is available from this preview.
class ProposalContentPreview extends StatefulWidget {
  const ProposalContentPreview({
    super.key,
    required this.load,
    required this.catalog,
    required this.relations,
    this.changes,
    this.readStoredFile,
    this.pendingReader,
    this.readingState,
  });
  final Future<WorkspaceProposalItem> Function() load;
  final WorkspaceCatalog catalog;
  final WorkspaceRelationSource relations;
  final Stream<WorkspaceRecordRef?>? changes;
  final ProposalStoredFileReader? readStoredFile;
  final ProposalReadingState? readingState;
  final ProposalPendingFileReader? Function(WorkspaceProposalItem)?
  pendingReader;
  @override
  State<ProposalContentPreview> createState() => _ProposalContentPreviewState();
}

class _ProposalContentPreviewState extends State<ProposalContentPreview> {
  WorkspaceProposalItem? _item;
  Object? _error;
  int _generation = 0;
  final _refresh = WorkspaceRefresh();
  StreamSubscription<WorkspaceRecordRef?>? _subscription;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    _listen();
  }

  Future<void> _reload({bool background = false}) => _refresh.run(() async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() => _error = null);
    try {
      final item = await widget.load();
      if (mounted && generation == _generation) {
        setState(() => _item = item);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _item = null;
          _error = error;
        });
      }
    }
  }, background: background);

  void _listen() {
    _subscription = widget.changes?.listen(
      (_) => unawaited(_reload(background: true)),
    );
  }

  @override
  void didUpdateWidget(ProposalContentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      unawaited(_subscription?.cancel());
      _listen();
      _item = null;
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _refresh.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            error is WorkspaceFailure ? error.message : '内容暂时无法读取。',
            style: libraryText(context, 14, color: UiPalette.of(context).muted),
          ),
          const SizedBox(height: 10),
          DesktopButton(
            onPressed: () => unawaited(_reload()),
            child: const Text('重新读取内容'),
          ),
        ],
      );
    }
    final item = _item;
    if (item == null) return const LinearProgressIndicator();
    final review = WorkspaceProposalItemReview.fromItem(item);
    final reading = item.originalProposalVersion == null
        ? widget.readingState
        : widget.readingState?.child(
            'proposal-version:${item.originalProposalVersion}',
          );
    return item.before == null
        ? ProposalItemReading(
            item: item,
            review: review,
            catalog: widget.catalog,
            relations: widget.relations,
            onRecord: (_) {},
            enabled: false,
            readStoredFile: widget.readStoredFile,
            readingState: reading,
            readPendingFile: widget.pendingReader?.call(item),
          )
        : ProposalItemComparison(
            item: item,
            review: review,
            catalog: widget.catalog,
            relations: widget.relations,
            onRecord: (_) {},
            enabled: false,
            readStoredFile: widget.readStoredFile,
            readingState: reading,
            readPendingFile: widget.pendingReader?.call(item),
          );
  }
}
