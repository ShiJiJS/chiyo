import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

/// Used only by a host picker. The editor receives one opaque staged material;
/// it does not choose a sample provider or know any of these candidate IDs.
Future<WorkspaceCredentialCandidate?> showWorkspaceCredentialChoices(
  BuildContext context,
  Future<List<WorkspaceCredentialCandidate>> Function() load, {
  WorkspaceCredentialForm? form,
}) => showDesktopDialog<WorkspaceCredentialCandidate>(
  context,
  builder: (_) => _CredentialChoices(load: load, form: form),
);

class _CredentialChoices extends StatefulWidget {
  const _CredentialChoices({required this.load, required this.form});
  final Future<List<WorkspaceCredentialCandidate>> Function() load;
  final WorkspaceCredentialForm? form;
  @override
  State<_CredentialChoices> createState() => _CredentialChoicesState();
}

class _CredentialChoicesState extends State<_CredentialChoices> {
  List<WorkspaceCredentialCandidate>? _choices;
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final choices = await widget.load();
      if (mounted) {
        setState(() {
          _choices = choices
              .where((c) => widget.form == null || c.form == widget.form)
              .toList();
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error is WorkspaceFailure ? error.message : '材料输入或选择暂不可用。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('凭据材料'),
    content: _loading
        ? const Text('正在准备材料入口…')
        : _error != null
        ? Text(_error!)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final candidate in _choices!)
                DesktopButton(
                  key: ValueKey('credential-candidate-${candidate.id}'),
                  kind: DesktopButtonKind.quiet,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.all(12),
                  onPressed: () => Navigator.pop(context, candidate),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        candidate.label,
                        style: libraryText(
                          context,
                          14,
                          weight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${candidate.format} · ${candidate.delivery.label}',
                        style: libraryText(
                          context,
                          13,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                      if (candidate.filename != null)
                        Text(
                          candidate.filename!,
                          style: libraryText(context, 13),
                        ),
                    ],
                  ),
                ),
              if (_choices!.isEmpty) const Text('没有可用材料。'),
            ],
          ),
    actions: [
      if (_error != null)
        DesktopButton(onPressed: _load, child: const Text('重试')),
      DesktopButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
