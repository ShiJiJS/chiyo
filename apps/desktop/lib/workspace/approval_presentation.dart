import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';

class ApprovalDetailRow extends StatelessWidget {
  const ApprovalDetailRow({
    super.key,
    required this.label,
    required this.value,
  });
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: libraryText(context, 12, color: UiPalette.of(context).muted),
        ),
        const SizedBox(height: 4),
        SelectableText(value, style: libraryText(context, 14, height: 1.7)),
      ],
    ),
  );
}

class CredentialBindingCard extends StatelessWidget {
  const CredentialBindingCard({
    super.key,
    required this.name,
    required this.version,
    required this.destination,
  });
  final String name, destination;
  final int version;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: c.rail,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.key_outlined, size: 18, color: c.accent),
              Text(
                name,
                style: libraryText(context, 14, weight: FontWeight.w600),
              ),
              Text(
                '第 $version 版',
                style: libraryText(context, 12, color: c.muted),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SelectableText(
            destination,
            style: libraryText(context, 14, height: 1.7),
          ),
        ],
      ),
    );
  }
}

/// Exact public values stay selectable, but long scripts cannot take over the
/// approval page. The viewport scrolls independently only after expansion.
class ApprovalExactDetails extends StatefulWidget {
  const ApprovalExactDetails({
    super.key,
    required this.title,
    required this.text,
    this.hint,
    this.initiallyExpanded = false,
  });
  final String title, text;
  final String? hint;
  final bool initiallyExpanded;
  @override
  State<ApprovalExactDetails> createState() => _ApprovalExactDetailsState();
}

class _ApprovalExactDetailsState extends State<ApprovalExactDetails> {
  late bool _expanded = widget.initiallyExpanded;
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButton(
            kind: DesktopButtonKind.quiet,
            leading: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '收起${widget.title}' : '查看${widget.title}'),
          ),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.rail,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.hint != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      widget.hint!,
                      style: libraryText(
                        context,
                        12,
                        color: c.muted,
                        height: 1.7,
                      ),
                    ),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      primary: false,
                      child: SelectableText(
                        widget.text,
                        style: libraryText(
                          context,
                          13,
                          height: 1.8,
                        ).copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Feedback belongs to the operation that was refreshed. The callback only
/// invokes the controller's existing reads, never a launch or replay.
class OperationRefresh extends StatefulWidget {
  const OperationRefresh({
    super.key,
    required this.controller,
    required this.operationId,
    required this.refresh,
    required this.observation,
  });
  final ApprovalsController controller;
  final String operationId;
  final Future<void> Function() refresh;
  final String Function() observation;
  @override
  State<OperationRefresh> createState() => _OperationRefreshState();
}

class _OperationRefreshState extends State<OperationRefresh> {
  String? _feedback;
  String? _request;
  @override
  void initState() {
    super.initState();
    _request = widget.controller.selection;
  }

  @override
  void didUpdateWidget(covariant OperationRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_request != widget.controller.selection ||
        oldWidget.operationId != widget.operationId) {
      _request = widget.controller.selection;
      _feedback = null;
    }
  }

  Future<void> _refresh() async {
    final before = widget.observation(), request = widget.controller.selection;
    setState(() => _feedback = null);
    await widget.refresh();
    if (!mounted ||
        widget.controller.selection != request ||
        widget.controller.executionError(widget.operationId) != null) {
      return;
    }
    setState(
      () => _feedback = before == widget.observation()
          ? '已刷新，状态暂无变化。'
          : '已刷新，已显示最新状态。',
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.controller,
        busy = widget.controller.readingExecution(widget.operationId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DesktopButton(
          kind: DesktopButtonKind.quiet,
          busy: busy,
          onPressed: model.frozen || model.loading || model.reading || busy
              ? null
              : _refresh,
          child: Text(busy ? '正在刷新…' : '刷新状态'),
        ),
        if (_feedback != null &&
            !busy &&
            model.executionError(widget.operationId) == null)
          Semantics(
            liveRegion: true,
            child: Text(
              _feedback!,
              style: libraryText(
                context,
                12,
                color: UiPalette.of(context).muted,
                height: 1.8,
              ),
            ),
          ),
      ],
    );
  }
}
