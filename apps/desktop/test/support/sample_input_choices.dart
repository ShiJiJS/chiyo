// Test fixtures only. Never imported by the application entry point.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/library_file_dialogs.dart'
    show workspaceFileSize;
import 'package:info_desktop/workspace/workspace_source.dart';

Future<WorkspaceFileCandidate?> showWorkspaceFileChoices(
  BuildContext context,
  Future<List<WorkspaceFileCandidate>> Function() load,
) => showDesktopDialog<WorkspaceFileCandidate>(
  context,
  builder: (_) => _FileChoices(load),
);

class _FileChoices extends StatefulWidget {
  const _FileChoices(this.load);
  final Future<List<WorkspaceFileCandidate>> Function() load;
  @override
  State<_FileChoices> createState() => _FileChoicesState();
}

class _FileChoicesState extends State<_FileChoices> {
  late Future<List<WorkspaceFileCandidate>> _choices = widget.load();
  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('选择文件'),
    content: FutureBuilder<List<WorkspaceFileCandidate>>(
      future: _choices,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Text('正在读取文件选择…');
        }
        if (snapshot.hasError) {
          return Column(
            children: [
              const Text('文件选择暂不可用。'),
              DesktopButton(
                onPressed: () => setState(() => _choices = widget.load()),
                child: const Text('重试'),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final file in snapshot.data ?? <WorkspaceFileCandidate>[])
              DesktopButton(
                key: ValueKey('library-file-choice-${file.selectionId}'),
                kind: DesktopButtonKind.quiet,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(12),
                onPressed: () => Navigator.pop(context, file),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(file.filename),
                    Text(
                      '${file.mediaType} · ${workspaceFileSize(file.byteLength)}',
                      style: libraryText(
                        context,
                        12,
                        color: UiPalette.of(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
            if (snapshot.data?.isEmpty ?? true) const Text('没有可选择的文件。'),
          ],
        );
      },
    ),
    actions: [
      DesktopButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

/// The composition root supplies host selection and releases unchosen leases.
Future<WorkspacePluginCandidate?> showPluginChoices(
  BuildContext context,
  Future<List<WorkspacePluginCandidate>> Function() read,
  Future<void> Function(String) release,
) async {
  final choices = await read();
  WorkspacePluginCandidate? selected;
  try {
    if (!context.mounted) return null;
    selected = await showDesktopDialog<WorkspacePluginCandidate>(
      context,
      builder: (context) => DesktopDialog(
        title: const Text('选择插件包'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final choice in choices)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DesktopButton(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.all(14),
                  onPressed: () => Navigator.pop(context, choice),
                  child: Text('${choice.filename} · ${choice.byteLength}字节'),
                ),
              ),
          ],
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    return selected;
  } finally {
    for (final c in choices) {
      if (c.selectionId != selected?.selectionId) await release(c.selectionId);
    }
  }
}

Future<WorkspaceHostFile?> showHostFileChoices(
  BuildContext context,
  Future<List<WorkspaceHostFile>> Function() read,
  Future<void> Function(String) release,
) async {
  final choices = await read();
  WorkspaceHostFile? selected;
  try {
    if (!context.mounted) return null;
    selected = await showDesktopDialog<WorkspaceHostFile>(
      context,
      builder: (context) => DesktopDialog(
        title: const Text('选择主机记录文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final file in choices)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DesktopButton(
                  alignment: Alignment.centerLeft,
                  onPressed: () => Navigator.pop(context, file),
                  child: Text('${file.name} · ${file.byteLength}字节'),
                ),
              ),
          ],
        ),
        actions: [
          DesktopButton(
            key: const ValueKey('host-file-choice-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    return selected;
  } finally {
    for (final file in choices) {
      if (selected?.selectionId != file.selectionId) {
        await release(file.selectionId);
      }
    }
  }
}

Future<WorkspaceBackupResource?> showWorkspaceBackupChoices(
  BuildContext context,
  Future<List<WorkspaceBackupResource>> Function() choices,
) => showDesktopDialog<WorkspaceBackupResource>(
  context,
  builder: (_) => _BackupChoices(choices: choices),
);

class _BackupChoices extends StatefulWidget {
  const _BackupChoices({required this.choices});
  final Future<List<WorkspaceBackupResource>> Function() choices;
  @override
  State<_BackupChoices> createState() => _BackupChoicesState();
}

class _BackupChoicesState extends State<_BackupChoices> {
  List<WorkspaceBackupResource>? _rows;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.choices();
      if (mounted) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _error = '文件选择暂不可用，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('选择文件或保存位置'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) ...[
          Text(_error!),
          DesktopButton(onPressed: _load, child: const Text('重新读取文件选择')),
        ],
        if (_rows != null && _rows!.isEmpty) const Text('没有可选择的文件。'),
        for (final row in _rows ?? <WorkspaceBackupResource>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DesktopButton(
              key: ValueKey('backup-resource-${row.id}'),
              alignment: Alignment.centerLeft,
              onPressed: _busy ? null : () => Navigator.pop(context, row),
              child: Text(row.name),
            ),
          ),
      ],
    ),
    actions: [
      DesktopButton(
        key: const ValueKey('backup-picker-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

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
