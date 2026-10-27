import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_history_dialog.dart';
import 'library_widgets.dart';
import 'proposal_reading.dart';
import 'workspace_source.dart';

class ProposalReadDialog extends StatefulWidget {
  const ProposalReadDialog({
    super.key,
    required this.source,
    required this.changes,
    required this.proposalId,
    required this.record,
    required this.label,
    this.item,
    this.review,
  });
  final WorkspaceProposalSource source;
  final Stream<WorkspaceRecordRef?> changes;
  final String proposalId, label;
  final WorkspaceRecordRef record;
  final WorkspaceProposalItem? item;
  final WorkspaceProposalItemReview? review;
  @override
  State<ProposalReadDialog> createState() => _ProposalReadDialogState();
}

class _ProposalReadDialogState extends State<ProposalReadDialog> {
  WorkspaceArchive? _archive;
  WorkspaceDetail? _current;
  WorkspaceFailure? _error;
  bool _loading = true;
  int _generation = 0;
  StreamSubscription<WorkspaceRecordRef?>? _subscription;
  @override
  void initState() {
    super.initState();
    _subscription = widget.changes.listen((ref) {
      if (ref == null || ref == widget.record) unawaited(_load());
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _archive = null;
      _current = null;
      _error = null;
    });
    try {
      final archive = widget.item == null
          ? await widget.source.snapshot(widget.proposalId, widget.record)
          : null;
      final current = widget.item != null
          ? await widget.source.currentTarget(widget.proposalId)
          : null;
      if (current != null && current.record.ref != widget.record) {
        throw const WorkspaceFailure('conflict', '返回的资料身份与原提案不符，请重新核对。');
      }
      if (mounted && generation == _generation) {
        setState(() {
          _archive = archive;
          _current = current;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '资料暂时无法读取，请重试。'),
        );
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

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text(widget.label),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!.message,
            style: libraryText(
              context,
              14,
              color: UiPalette.of(context).danger,
            ),
          ),
        if (_archive != null) LibrarySnapshotView(archive: _archive!),
        if (_current case final current?) ...[
          Text(
            '${current.record.name} · 当前资料v${current.version}',
            style: libraryText(context, 18, weight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            '这里只核对当前内容，不会写入资料。原提案不会自动换用新的资料版本。',
            style: libraryText(
              context,
              13,
              color: UiPalette.of(context).muted,
              height: 1.9,
            ),
          ),
          for (final change in widget.item!.changes)
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: ProposalDiff(
                label: change.label,
                before: current.fieldIds[change.key] == change.fieldId
                    ? proposalValue(current.values[change.key])
                    : '原字段已删除或替换，不能按同名字段对应。',
                after: proposalValue(widget.review!.values[change.key]),
              ),
            ),
        ],
      ],
    ),
    actions: [
      if (_error != null)
        DesktopButton(
          onPressed: _loading ? null : _load,
          child: const Text('重新读取'),
        ),
      DesktopButton(
        key: const ValueKey('proposal-read-close'),
        onPressed: () => Navigator.pop(context),
        child: Text(widget.item == null ? '关闭' : '保留原审阅并返回'),
      ),
    ],
  );
}
