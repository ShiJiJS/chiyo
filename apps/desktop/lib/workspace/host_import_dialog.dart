import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'host_import_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

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

Future<WorkspaceHostImportReceipt?> showHostFileImport(
  BuildContext context,
  WorkspaceHostSource source,
  WorkspaceHostFilePicker picker,
) => showDesktopDialog<WorkspaceHostImportReceipt>(
  context,
  builder: (_) => _HostFileImport(source: source, picker: picker),
);

class _HostFileImport extends StatefulWidget {
  const _HostFileImport({required this.source, required this.picker});
  final WorkspaceHostSource source;
  final WorkspaceHostFilePicker picker;
  @override
  State<_HostFileImport> createState() => _HostFileImportState();
}

class _HostFileImportState extends State<_HostFileImport> {
  late final HostImportController m;
  @override
  void initState() {
    super.initState();
    m = HostImportController(widget.source)..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pick();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final chosen = await m.pick(widget.picker);
    if (mounted && !chosen && m.file == null) Navigator.pop(context);
  }

  Future<void> _complete(Future<void> action) async {
    await action;
    if (mounted && m.result != null) Navigator.pop(context, m.result);
  }

  @override
  void dispose() {
    m.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), p = m.preview;
    return PopScope<WorkspaceHostImportReceipt>(
      canPop: !m.frozen,
      child: DesktopDialog(
        title: const Text('导入主机记录'),
        closeEnabled: !m.frozen,
        onClose: m.frozen ? null : () => Navigator.pop(context),
        content: SizedBox(
          width: 680,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (m.busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(),
                ),
              if (m.failure != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    m.failure!.message,
                    style: libraryText(
                      context,
                      14,
                      color: c.danger,
                      height: 1.8,
                    ),
                  ),
                ),
              if (m.file case final file?) ...[
                Text(
                  file.name,
                  style: libraryText(context, 17, weight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '${file.byteLength} 字节 · known_hosts',
                  style: libraryText(context, 13, color: c.muted),
                ),
              ],
              if (p != null) ...[
                const SizedBox(height: 14),
                SelectableText(
                  'SHA256 ${p.digest}',
                  style: libraryText(context, 12, color: c.muted),
                ),
                const SizedBox(height: 18),
                Text(
                  '${p.entries.length} 条主机记录',
                  style: libraryText(context, 15, weight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  p.previous == null
                      ? '核对文件来源及每条公钥指纹后确认。'
                      : '将替换已导入的文件记录：${p.previous!.name}。请核对新旧来源。',
                  style: libraryText(context, 13, color: c.muted, height: 1.8),
                ),
                for (final entry in p.entries.take(20))
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          entry.pattern,
                          style: libraryText(
                            context,
                            14,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          [
                            if (entry.marker != null) entry.marker!,
                            entry.keyType,
                          ].join(' · '),
                          style: libraryText(context, 12, color: c.muted),
                        ),
                        SelectableText(
                          entry.fingerprint,
                          style: libraryText(context, 13),
                        ),
                      ],
                    ),
                  ),
                if (p.entries.length > 20)
                  Text(
                    '另有 ${p.entries.length - 20} 条；确认作用于整份文件。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                const SizedBox(height: 18),
                Text(
                  '现有逐台主机确认记录保持不变。导入不代表允许资料访问或凭据使用。',
                  style: libraryText(context, 13, color: c.muted, height: 1.8),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (m.uncertain)
            DesktopButton(
              key: const ValueKey('host-import-reconcile'),
              onPressed: m.busy ? null : () => _complete(m.reconcile()),
              child: const Text('核对本次导入'),
            ),
          DesktopButton(
            key: const ValueKey('host-import-pick'),
            onPressed: m.frozen ? null : _pick,
            child: const Text('重新选择'),
          ),
          if (m.file != null)
            DesktopButton(
              key: const ValueKey('host-import-review'),
              onPressed: m.frozen ? null : m.review,
              child: const Text('重新读取'),
            ),
          DesktopButton(
            key: const ValueKey('host-import-cancel'),
            onPressed: m.frozen ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('host-import-submit'),
            kind: DesktopButtonKind.primary,
            busy: m.busy && m.preview != null,
            onPressed: m.canSubmit ? () => _complete(m.submit()) : null,
            child: const Text('确认导入文件'),
          ),
        ],
      ),
    );
  }
}
