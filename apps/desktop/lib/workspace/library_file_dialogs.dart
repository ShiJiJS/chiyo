import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

String workspaceFileSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// The same complete file identity in selection, history and change review.
/// No original bytes or local paths are needed to make this decision.
class LibraryFileSummary extends StatelessWidget {
  const LibraryFileSummary({
    super.key,
    required this.label,
    required this.filename,
    required this.mediaType,
    required this.byteLength,
    this.createdAt,
  });
  final String label, filename, mediaType;
  final int byteLength;
  final DateTime? createdAt;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: libraryText(context, 13, color: c.muted)),
        const SizedBox(height: 8),
        SelectableText(
          filename,
          style: libraryText(context, 14, weight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        SelectableText(
          '$mediaType · ${workspaceFileSize(byteLength)}（$byteLength 字节）',
          style: libraryText(context, 13, color: c.muted),
        ),
        if (createdAt != null)
          Text(
            '创建于 ${libraryLocalDateTime(createdAt!)}',
            style: libraryText(context, 13, color: c.muted),
          ),
      ],
    );
  }
}

Future<WorkspaceRecordRef?> showLibraryFileImport(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceCatalog catalog,
  WorkspaceFilePicker? picker,
  String? directoryId,
) async {
  WorkspaceFileCandidate? selected;
  try {
    if (picker == null) {
      throw const WorkspaceFailure('unsupported', '文件选择服务不可用。');
    }
    selected = await picker();
  } catch (error) {
    if (!context.mounted) return null;
    await showDesktopDialog<void>(
      context,
      builder: (context) => DesktopDialog(
        title: const Text('暂时无法选择文件'),
        content: Text(
          error is WorkspaceFailure ? error.message : '文件选择暂不可用，请重试。',
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    return null;
  }
  final candidate = selected;
  if (candidate == null) return null;
  try {
    if (!context.mounted) return null;
    return await showDesktopDialog<WorkspaceRecordRef>(
      context,
      builder: (_) => _ImportFile(
        source: source,
        catalog: catalog,
        selected: candidate,
        directoryId: directoryId,
      ),
    );
  } finally {
    if (source is WorkspaceFileSelectionReleaser) {
      await (source as WorkspaceFileSelectionReleaser).releaseFileSelection(
        candidate.selectionId,
      );
    }
  }
}

class _ImportFile extends StatefulWidget {
  const _ImportFile({
    required this.source,
    required this.catalog,
    required this.selected,
    required this.directoryId,
  });
  final WorkspaceSource source;
  final WorkspaceCatalog catalog;
  final WorkspaceFileCandidate selected;
  final String? directoryId;
  @override
  State<_ImportFile> createState() => _ImportFileState();
}

class _ImportFileState extends State<_ImportFile> {
  late final _name = TextEditingController(text: widget.selected.filename);
  final _description = TextEditingController();
  late String? _directory = ['all', 'unfiled'].contains(widget.directoryId)
      ? null
      : widget.directoryId;
  bool _busy = false, _discard = false, _dirty = false;
  WorkspaceFailure? _failure;
  String? _operation, _submittedDigest;
  bool get _uncertain => _failure?.code == 'unknown_outcome';
  void _close(WorkspaceRecordRef ref) {
    setState(() {
      _busy = _dirty = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, ref);
    });
  }

  Future<void> _lookup() async {
    setState(() => _busy = true);
    try {
      final receipt = await widget.source.fileOperationReceipt(_operation!);
      if (!mounted) return;
      if (receipt != null) {
        if (receipt.commandDigest != null &&
            (receipt.commandDigest != _submittedDigest ||
                receipt.file == null ||
                receipt.record.kind != WorkspaceRecordKind.information)) {
          throw const WorkspaceFailure(
            'unknown_outcome',
            '文件回执与原导入操作不符，请继续核对。',
          );
        }
        _close(receipt.record);
        return;
      }
      setState(() {
        _busy = false;
        _operation = null;
        _failure = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = const WorkspaceFailure(
            'unknown_outcome',
            '仍无法确认导入结果，请稍后核对。',
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final command = WorkspaceFileImport(
        operationId: _operation ??= workspaceFileOperationId(),
        selectionId: widget.selected.selectionId,
        name: _name.text,
        description: _description.text,
        directoryId: _directory,
      );
      _submittedDigest = command.digest;
      final ref = await widget.source.importFile(command);
      if (!mounted) return;
      _close(ref);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure(
                'unknown_outcome',
                '暂时无法确认导入结果，请核对信息库后再继续。',
              );
        if (_failure!.code != 'unknown_outcome') _operation = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_dirty && !_uncertain,
    onPopInvokedWithResult: (popped, _) {
      if (!popped && !_busy && !_uncertain) setState(() => _discard = true);
    },
    child: DesktopDialog(
      title: const Text('导入文件'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LibraryFileSummary(
            label: '已选择的文件',
            filename: widget.selected.filename,
            mediaType: widget.selected.mediaType,
            byteLength: widget.selected.byteLength,
          ),
          const SizedBox(height: 18),
          const Text('文件名、资料名称与用途可能出现在公开目录，请核对后导入。'),
          const SizedBox(height: 18),
          DesktopTextField(
            key: const ValueKey('library-file-import-name'),
            controller: _name,
            enabled: !_busy && !_uncertain,
            onChanged: (_) => setState(() {
              _dirty = true;
              _operation = null;
            }),
            decoration: InputDecoration(
              labelText: '资料名称',
              errorText: _failure?.fieldErrors['name'],
            ),
          ),
          DesktopTextField(
            key: const ValueKey('library-file-import-description'),
            controller: _description,
            enabled: !_busy && !_uncertain,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {
              _dirty = true;
              _operation = null;
            }),
            decoration: InputDecoration(
              labelText: '用途说明',
              errorText: _failure?.fieldErrors['description'],
            ),
          ),
          LibraryDirectorySelect(
            catalog: widget.catalog,
            value: _directory,
            onChanged: _busy || _uncertain
                ? null
                : (value) => setState(() {
                    _directory = value;
                    _dirty = true;
                    _operation = null;
                  }),
          ),
        ],
      ),
      actions: [
        if (_failure != null)
          SizedBox(
            width: double.infinity,
            child: Text(
              _failure!.message,
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).danger,
              ),
            ),
          ),
        if (_uncertain)
          DesktopButton(
            onPressed: _busy ? null : _lookup,
            child: const Text('核对导入结果'),
          ),
        if (_discard)
          SizedBox(
            width: double.infinity,
            child: Text(
              '尚有未保存的修改。',
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).warning,
              ),
            ),
          ),
        if (_discard)
          DesktopButton(
            onPressed: _busy || _uncertain
                ? null
                : () {
                    setState(() => _dirty = false);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) Navigator.pop(context);
                    });
                  },
            child: const Text('放弃修改'),
          ),
        DesktopButton(
          onPressed: _busy || _uncertain
              ? null
              : () {
                  if (_dirty) {
                    setState(() => _discard = true);
                  } else {
                    Navigator.pop(context);
                  }
                },
          child: const Text('取消'),
        ),
        DesktopButton(
          key: const ValueKey('library-file-import-submit'),
          busy: _busy,
          kind: DesktopButtonKind.primary,
          onPressed: _failure?.code == 'unknown_outcome' ? null : _save,
          child: const Text('导入'),
        ),
      ],
    ),
  );
}

Future<bool?> showLibraryFileChange(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceRecordRef record,
  String fieldKey,
  WorkspaceFileHistory history, {
  WorkspaceFileCandidate? selected,
  int? restoreVersion,
  WorkspaceFileRef? restoreRef,
}) async {
  try {
    return await showDesktopDialog<bool>(
      context,
      builder: (_) => _FileChange(
        source: source,
        record: record,
        fieldKey: fieldKey,
        history: history,
        selected: selected,
        restoreVersion: restoreVersion,
        restoreRef: restoreRef,
      ),
    );
  } finally {
    if (selected != null && source is WorkspaceFileSelectionReleaser) {
      await (source as WorkspaceFileSelectionReleaser).releaseFileSelection(
        selected.selectionId,
      );
    }
  }
}

class _FileChange extends StatefulWidget {
  const _FileChange({
    required this.source,
    required this.record,
    required this.fieldKey,
    required this.history,
    this.selected,
    this.restoreVersion,
    this.restoreRef,
  });
  final WorkspaceSource source;
  final WorkspaceRecordRef record;
  final String fieldKey;
  final WorkspaceFileHistory history;
  final WorkspaceFileCandidate? selected;
  final int? restoreVersion;
  final WorkspaceFileRef? restoreRef;
  @override
  State<_FileChange> createState() => _FileChangeState();
}

class _FileChangeState extends State<_FileChange> {
  bool _busy = false;
  WorkspaceFailure? _failure;
  late WorkspaceFileHistory _history = widget.history;
  String? _operation, _submittedDigest;
  late final WorkspaceFileRef? _restoreRef =
      widget.restoreRef ??
      widget.history.versions
          .where((file) => file.ref.version == widget.restoreVersion)
          .firstOrNull
          ?.ref;
  WorkspaceFileVersion? get _restoreTarget =>
      _history.versions.where((file) => file.ref == _restoreRef).firstOrNull;
  bool get _targetAvailable =>
      widget.selected != null || _restoreTarget?.available == true;
  Future<void> _submit() async {
    if (_busy || !_targetAvailable) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final command = WorkspaceFileChange(
        operationId: _operation ??= workspaceFileOperationId(),
        record: widget.record,
        fieldKey: widget.fieldKey,
        expectedRecordVersion: _history.recordVersion,
        expectedFileVersion: _history.current.ref.version,
        kind: widget.restoreVersion == null
            ? WorkspaceFileChangeKind.replace
            : WorkspaceFileChangeKind.restore,
        selectionId: widget.selected?.selectionId,
        restoreVersion: widget.restoreVersion,
        restoreRef: _restoreRef,
      );
      _submittedDigest = command.digest;
      await widget.source.changeFile(command);
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '暂时无法确认结果，请重新读取核对。');
        if (_failure!.code != 'unknown_outcome') _operation = null;
      });
    }
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      if (_failure?.code == 'unknown_outcome' && _operation != null) {
        final receipt = await widget.source.fileOperationReceipt(_operation!);
        if (!mounted) return;
        if (receipt != null) {
          if (receipt.commandDigest != null &&
              (receipt.commandDigest != _submittedDigest ||
                  receipt.record != widget.record ||
                  (receipt.file?.version ?? 0) <=
                      _history.current.ref.version)) {
            throw const WorkspaceFailure(
              'unknown_outcome',
              '文件回执与原变更操作不符，请继续核对。',
            );
          }
          setState(() => _busy = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context, true);
          });
          return;
        }
      }
      final history = await widget.source.loadFileHistory(
        widget.record,
        widget.fieldKey,
      );
      if (!mounted) return;
      setState(() {
        _history = history;
        _busy = false;
        _operation = null;
        _failure = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = _failure?.code == 'unknown_outcome'
              ? const WorkspaceFailure('unknown_outcome', '仍无法确认结果，请稍后核对。')
              : error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '文件版本暂不可用。');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && _failure?.code != 'unknown_outcome',
    child: DesktopDialog(
      title: Text(widget.restoreVersion == null ? '替换文件' : '恢复文件版本'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LibraryFileSummary(
            key: const ValueKey('library-file-change-current'),
            label: '当前文件 · v${_history.current.ref.version}',
            filename: _history.current.filename,
            mediaType: _history.current.mediaType,
            byteLength: _history.current.byteLength,
            createdAt: _history.current.createdAt,
          ),
          const SizedBox(height: 12),
          if (widget.selected case final file?) ...[
            LibraryFileSummary(
              key: const ValueKey('library-file-change-target'),
              label: '替换为新文件版本',
              filename: file.filename,
              mediaType: file.mediaType,
              byteLength: file.byteLength,
            ),
          ] else if (_restoreTarget case final file?) ...[
            LibraryFileSummary(
              key: const ValueKey('library-file-change-target'),
              label: '恢复来源 · 历史 v${file.ref.version}',
              filename: file.filename,
              mediaType: file.mediaType,
              byteLength: file.byteLength,
              createdAt: file.createdAt,
            ),
            const SizedBox(height: 12),
            Text('恢复后创建新文件版本 v${_history.current.ref.version + 1}，保留当前文件。'),
          ] else
            Semantics(
              liveRegion: true,
              child: Text(
                '所选历史版本已不在当前保留列表中，请返回文件版本重新选择。',
                key: const ValueKey('library-file-change-target-unavailable'),
                style: libraryText(
                  context,
                  14,
                  color: UiPalette.of(context).danger,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            _targetAvailable ? '旧文件版本仍可查看；已有授权不会因此恢复或扩大。' : '已有授权不会因此恢复或扩大。',
          ),
        ],
      ),
      actions: [
        if (_failure != null)
          SizedBox(
            width: double.infinity,
            child: Text(
              _failure!.message,
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).danger,
              ),
            ),
          ),
        if ([
          'conflict',
          'unknown_outcome',
          'cancelled',
        ].contains(_failure?.code))
          DesktopButton(
            onPressed: _busy ? null : _reload,
            child: const Text('重新读取核对'),
          ),
        DesktopButton(
          onPressed: _busy || _failure?.code == 'unknown_outcome'
              ? null
              : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        DesktopButton(
          key: const ValueKey('library-file-change-submit'),
          kind: DesktopButtonKind.primary,
          busy: _busy,
          onPressed:
              !_targetAvailable ||
                  [
                    'conflict',
                    'unknown_outcome',
                    'cancelled',
                  ].contains(_failure?.code)
              ? null
              : _submit,
          child: Text(widget.restoreVersion == null ? '替换文件' : '恢复此版本'),
        ),
      ],
    ),
  );
}
