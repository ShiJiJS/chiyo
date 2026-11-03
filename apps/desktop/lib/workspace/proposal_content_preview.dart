import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'proposal_reading.dart';
import 'workspace_source.dart';

/// Loads exact Owner-only content in place. No library route or management
/// action is available from this preview.
class ProposalContentPreview extends StatefulWidget {
  const ProposalContentPreview({
    super.key,
    required this.load,
    required this.catalog,
    required this.relations,
    this.changes,
  });
  final Future<WorkspaceProposalItem> Function() load;
  final WorkspaceCatalog catalog;
  final WorkspaceRelationSource relations;
  final Stream<WorkspaceRecordRef?>? changes;
  @override
  State<ProposalContentPreview> createState() => _ProposalContentPreviewState();
}

class _ProposalContentPreviewState extends State<ProposalContentPreview> {
  late Future<WorkspaceProposalItem> _content;
  StreamSubscription<WorkspaceRecordRef?>? _subscription;
  Future<WorkspaceProposalItem> _read() {
    final future = widget.load();
    // Changes may replace the future before a frame attaches FutureBuilder.
    // Observe errors immediately; the active builder still displays them.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  @override
  void initState() {
    super.initState();
    _content = _read();
    _subscription = widget.changes?.listen((_) {
      if (mounted) {
        setState(() {
          _content = _read();
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<WorkspaceProposalItem>(
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
            Text(
              error is WorkspaceFailure ? error.message : '内容暂时无法读取。',
              style: libraryText(
                context,
                14,
                color: UiPalette.of(context).muted,
              ),
            ),
            const SizedBox(height: 10),
            DesktopButton(
              onPressed: () => setState(() {
                _content = _read();
              }),
              child: const Text('重新读取内容'),
            ),
          ],
        );
      }
      final item = result.data;
      if (item == null) return const LinearProgressIndicator();
      final review = WorkspaceProposalItemReview.fromItem(item);
      return item.before == null
          ? ProposalItemReading(
              item: item,
              review: review,
              catalog: widget.catalog,
              relations: widget.relations,
              onRecord: (_) {},
              enabled: false,
            )
          : ProposalItemComparison(
              item: item,
              review: review,
              catalog: widget.catalog,
              relations: widget.relations,
              onRecord: (_) {},
              enabled: false,
            );
    },
  );
}
