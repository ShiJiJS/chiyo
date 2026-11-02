import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import '../desktop_scroll.dart';
import 'library_file_dialogs.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

enum _FileAction { replace, save, open, refresh }

class LibraryFile extends StatefulWidget {
  const LibraryFile({
    super.key,
    required this.detail,
    required this.fieldKey,
    required this.source,
    this.picker,
    this.onModalChanged,
  });
  final WorkspaceDetail detail;
  final String fieldKey;
  final WorkspaceSource source;
  final WorkspaceFilePicker? picker;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<LibraryFile> createState() => _LibraryFileState();
}

class _LibraryFileState extends State<LibraryFile> {
  WorkspaceFileHistory? _history;
  WorkspaceFilePreview? _preview;
  WorkspaceFailure? _metadataFailure, _previewFailure, _actionFailure;
  bool _loading = true, _previewLoading = true, _busy = false;
  int _generation = 0, _page = 0;
  String? _pendingAction;
  WorkspaceFileAction? _pendingKind;
  String? _pendingDigest;
  WorkspaceFileRef? _pendingFile;
  int _cleanupPending = 0, _openCopies = 0, _openCleanupPending = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LibraryFile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedContext =
        oldWidget.detail.record.ref != widget.detail.record.ref ||
        oldWidget.fieldKey != widget.fieldKey ||
        !identical(oldWidget.source, widget.source);
    if (changedContext || oldWidget.detail.version != widget.detail.version) {
      if (changedContext) {
        _page = 0;
        _history = null;
        _preview = null;
        _pendingAction = _pendingDigest = null;
        _pendingFile = null;
        _cleanupPending = _openCopies = _openCleanupPending = 0;
      }
      unawaited(_load());
    }
  }

  WorkspaceFailure _failure(Object error) => error is WorkspaceFailure
      ? error
      : const WorkspaceFailure('unavailable', '文件暂时无法读取，请重试。');
  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = _previewLoading = true;
      // Keep the mounted reader during metadata revalidation, hidden until
      // the attachment version is confirmed. Its reading state belongs to the
      // immutable attachment ref, not to the enclosing record's revision.
      _metadataFailure = _previewFailure = null;
    });
    try {
      final history = await widget.source.loadFileHistory(
        widget.detail.record.ref,
        widget.fieldKey,
      );
      final recovery = widget.source;
      final state = recovery is WorkspaceFileActionRecovery
          ? await (recovery as WorkspaceFileActionRecovery).fileActionState(
              widget.detail.record.ref,
              widget.fieldKey,
            )
          : null;
      if (!mounted || generation != _generation) return;
      setState(() {
        if (state?.pending case final pending?) {
          _pendingAction = pending.operationId;
          _pendingDigest = pending.digest;
          _pendingFile = pending.file;
          _pendingKind = pending.action;
        }
        _cleanupPending = state?.cleanupPending ?? 0;
        _openCopies = state?.openCopies ?? 0;
        _openCleanupPending = state?.openCleanupPending ?? 0;
        if (_history?.current.ref != history.current.ref) _page = 0;
        _history = history;
        _loading = false;
      });
      await _readPreview(generation);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _metadataFailure = _failure(error);
          _loading = _previewLoading = false;
        });
      }
    }
  }

  Future<void> _readPreview(int generation) async {
    try {
      final preview = await widget.source.readFilePreview(
        widget.detail.record.ref,
        widget.fieldKey,
        version: _history?.current.ref.version,
        page: _page,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _preview = preview;
          _previewLoading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _previewFailure = _failure(error);
          _previewLoading = false;
        });
      }
    }
  }

  void _turn(int page) {
    if (_loading || _metadataFailure != null) return;
    final generation = ++_generation;
    setState(() {
      _page = page;
      _previewFailure = null;
      _previewLoading = true;
    });
    unawaited(_readPreview(generation));
  }

  Future<void> _modal(Future<void> Function() action) async {
    if (_busy || _loading || _metadataFailure != null) return;
    DesktopFeedback.dismiss(context);
    setState(() => _busy = true);
    widget.onModalChanged?.call(true);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _actionFailure = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _metadata() => _modal(() async {
    final file = _history?.current;
    if (file == null) return;
    await showDesktopDialog<void>(
      context,
      builder: (context) => DesktopDialog(
        title: const Text('文件信息'),
        content: SelectableText(
          '文件名：${file.filename}\n格式：${file.mediaType}\n大小：${workspaceFileSize(file.byteLength)}（${file.byteLength} 字节）\n文件版本：v${file.ref.version}',
          key: const ValueKey('library-file-metadata-content'),
          style: libraryText(context, 14, height: 1.8),
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  });

  Future<void> _replace() => _modal(() async {
    final picker = widget.picker;
    if (picker == null) {
      throw const WorkspaceFailure('unsupported', '文件选择服务不可用。');
    }
    final selected = await picker();
    if (!mounted || selected == null || _history == null) return;
    final result = await showLibraryFileChange(
      context,
      widget.source,
      widget.detail.record.ref,
      widget.fieldKey,
      _history!,
      selected: selected,
    );
    if (result == true && mounted) {
      DesktopFeedback.show(context, '已替换文件');
      await _load();
    }
  });
  Future<void> _versions() => _modal(() async {
    if (_history == null) return;
    final restored = await showDesktopDialog<bool>(
      context,
      builder: (_) => _FileVersions(
        source: widget.source,
        record: widget.detail.record.ref,
        fieldKey: widget.fieldKey,
        history: _history!,
      ),
    );
    if (restored == true && mounted) {
      DesktopFeedback.show(context, '已恢复文件版本');
      await _load();
    }
  });
  Future<void> _action(WorkspaceFileAction action) async {
    if (_history == null ||
        _loading ||
        _metadataFailure != null ||
        _busy ||
        _pendingAction != null) {
      return;
    }
    final operation = workspaceFileOperationId();
    setState(() {
      _busy = true;
      _actionFailure = null;
      _pendingAction = operation;
      _pendingKind = action;
      _pendingFile = _history!.current.ref;
      _pendingDigest = workspaceFileActionDigest(
        widget.detail.record.ref,
        widget.fieldKey,
        _history!.current.ref.version,
        action,
      );
    });
    try {
      final result = await widget.source.fileAction(
        widget.detail.record.ref,
        widget.fieldKey,
        _history!.current.ref.version,
        action,
        operationId: operation,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pendingAction = null;
        if (result.cleanupPending) _cleanupPending++;
        if (result.completed && action == WorkspaceFileAction.open) {
          _openCopies++;
        }
      });
      if (result.completed) {
        DesktopFeedback.show(
          context,
          action == WorkspaceFileAction.saveAs
              ? '已另存 ${result.filename}'
              : '已交给本机程序打开 ${result.filename}',
        );
      }
    } catch (error) {
      if (!mounted) return;
      final failure = error is WorkspaceFailure
          ? error
          : const WorkspaceFailure('unknown_outcome', '暂时无法确认操作结果，请先核对。');
      setState(() {
        _busy = false;
        _actionFailure = failure;
        if (!{
          'unknown_outcome',
          'file_access_required',
        }.contains(failure.code)) {
          _pendingAction = null;
        }
      });
      if ({'not_opened', 'previous_pending'}.contains(failure.code)) {
        await _load();
      }
    }
  }

  Future<void> _lookupAction() async {
    if (_pendingAction == null || _busy) return;
    setState(() => _busy = true);
    try {
      final receipt = await widget.source.fileOperationReceipt(_pendingAction!);
      if (!mounted) return;
      if (receipt != null &&
          (receipt.record != widget.detail.record.ref ||
              receipt.file != _pendingFile ||
              receipt.actionCompleted == null ||
              receipt.commandDigest != null &&
                  receipt.commandDigest != _pendingDigest)) {
        throw const WorkspaceFailure('unknown_outcome', '返回的结果与原操作不一致，请继续核对。');
      }
      setState(() {
        _busy = false;
        _pendingAction = null;
        _actionFailure = null;
        if (receipt?.cleanupPending == true) {
          if (_pendingKind == WorkspaceFileAction.open) {
            _openCleanupPending++;
          } else {
            _cleanupPending++;
          }
        }
        if (receipt?.actionCompleted == true &&
            receipt?.openCopyHeld != false &&
            _pendingKind == WorkspaceFileAction.open) {
          _openCopies++;
        }
      });
      if (receipt?.actionCompleted == true) {
        DesktopFeedback.show(
          context,
          _pendingKind == WorkspaceFileAction.saveAs ? '另存操作已完成' : '系统已接收打开请求',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _actionFailure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unknown_outcome', '仍无法确认操作结果，请稍后核对。');
        });
      }
    }
  }

  Future<void> _recoverAccess() async {
    final recovery = widget.source;
    if (recovery is! WorkspaceFileActionRecovery ||
        _pendingAction == null ||
        _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await (recovery as WorkspaceFileActionRecovery).recoverFileActionAccess(
        _pendingAction!,
      );
    } catch (e) {
      if (mounted) setState(() => _actionFailure = _failure(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _lookupAction();
  }

  Future<void> _cleanup() async {
    final recovery = widget.source;
    if (recovery is! WorkspaceFileActionRecovery || _busy) return;
    setState(() => _busy = true);
    try {
      await (recovery as WorkspaceFileActionRecovery).cleanupFileActions(
        widget.detail.record.ref,
        widget.fieldKey,
      );
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _actionFailure = _failure(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishOpen({bool all = false}) async {
    final recovery = widget.source;
    if (recovery is! WorkspaceFileOpenRecovery || _busy) return;
    final id = _pendingAction;
    setState(() => _busy = true);
    try {
      if (all) {
        await (recovery as WorkspaceFileOpenRecovery).closeOpenFileCopies(
          widget.detail.record.ref,
          widget.fieldKey,
        );
      } else if (id != null) {
        await (recovery as WorkspaceFileOpenRecovery).finishFileOpen(id);
      }
      if (mounted) {
        setState(() {
          if (all || _pendingKind == WorkspaceFileAction.open) {
            _pendingAction = null;
          }
          _actionFailure = null;
        });
        DesktopFeedback.show(
          context,
          all ? '临时副本已清理' : '已结束核对并清理临时副本；未确认的打开结果仍保持未知',
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _actionFailure = _failure(e));
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), history = _history;
    if (_loading && history == null) return const Text('正在读取文件信息…');
    if (history == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_metadataFailure?.message ?? '文件信息不可用。'),
          DesktopButton(onPressed: _load, child: const Text('重新读取文件')),
        ],
      );
    }
    final blocked =
        _busy || _pendingAction != null || _loading || _metadataFailure != null;
    final visiblePreview =
        !_loading &&
        _metadataFailure == null &&
        !_previewLoading &&
        _previewFailure == null &&
        _preview != null;
    final toolbar = <Widget>[
      DesktopButton(
        key: ValueKey('library-file-versions-${widget.fieldKey}'),
        kind: DesktopButtonKind.quiet,
        fontSize: 13,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        tooltip: '文件版本 · 当前 v${history.current.ref.version}',
        selected: true,
        onPressed: blocked ? null : _versions,
        child: Text('v${history.current.ref.version} · 已选用'),
      ),
      Tooltip(
        message: history.current.filename,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width <= 1300 ? 100 : 180,
          ),
          child: SelectableText(
            history.current.filename,
            maxLines: 1,
            key: ValueKey('library-file-filename-${widget.fieldKey}'),
            style: libraryText(context, 13),
          ),
        ),
      ),
      DesktopButton(
        key: ValueKey('library-file-metadata-${widget.fieldKey}'),
        tooltip:
            '${history.current.mediaType} · ${workspaceFileSize(history.current.byteLength)} · v${history.current.ref.version} · 查看文件信息',
        kind: DesktopButtonKind.quiet,
        fontSize: 13,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        onPressed: blocked ? null : _metadata,
        child: Text(switch (history.current.mediaType) {
          'application/pdf' => 'PDF',
          'image/png' => 'PNG',
          'text/plain' => 'TXT',
          _ => '文件信息',
        }),
      ),
      DesktopSelect<_FileAction>(
        key: ValueKey('library-file-actions-${widget.fieldKey}'),
        compact: true,
        toolbar: true,
        quiet: true,
        tooltip: '文件操作',
        triggerLabel: const Text('文件操作'),
        minimumTriggerSize: const Size(32, 32),
        triggerPadding: const EdgeInsets.all(6),
        onChanged: (action) {
          switch (action) {
            case _FileAction.replace:
              unawaited(_replace());
            case _FileAction.save:
              unawaited(_action(WorkspaceFileAction.saveAs));
            case _FileAction.open:
              unawaited(_action(WorkspaceFileAction.open));
            case _FileAction.refresh:
              _turn(_page);
            case null:
              break;
          }
        },
        items: [
          for (final (action, id, label) in const [
            (_FileAction.replace, 'replace', '替换文件'),
            (_FileAction.save, 'save', '另存为'),
            (_FileAction.open, 'open', '用本机程序打开'),
            (_FileAction.refresh, 'preview-refresh', '刷新预览'),
          ])
            DropdownMenuItem(
              value: action,
              enabled: action == _FileAction.refresh
                  ? !_loading && _metadataFailure == null && !_previewLoading
                  : !blocked,
              child: Text(
                label,
                key: ValueKey('library-file-$id-${widget.fieldKey}'),
              ),
            ),
        ],
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading) const Text('正在读取文件信息…'),
        if (_metadataFailure case final failure?) ...[
          Text(
            failure.message,
            style: libraryText(context, 13, color: c.danger),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(onPressed: _load, child: const Text('重新读取文件')),
          ),
        ],
        if (!visiblePreview)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: toolbar,
          ),
        if (_actionFailure != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _actionFailure!.message,
              style: libraryText(context, 13, color: c.danger),
            ),
          ),
        if (_pendingAction != null && !_busy)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              onPressed: _lookupAction,
              child: const Text('核对此次操作'),
            ),
          ),
        if (_pendingAction != null &&
            !_busy &&
            widget.source is WorkspaceFileActionRecovery &&
            _pendingKind == WorkspaceFileAction.saveAs)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              onPressed: _recoverAccess,
              child: const Text('重新选择原文件并核对'),
            ),
          ),
        if (_cleanupPending > 0)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('有 $_cleanupPending 项另存暂存等待清理'),
              DesktopButton(
                onPressed: _busy ? null : _cleanup,
                child: const Text('重试清理暂存'),
              ),
            ],
          ),
        if (_pendingAction != null &&
            _pendingKind == WorkspaceFileAction.open &&
            widget.source is WorkspaceFileOpenRecovery)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              onPressed: _busy ? null : () => _finishOpen(),
              child: const Text('结束核对并清理临时副本'),
            ),
          ),
        if (_openCopies > 0 || _openCleanupPending > 0) ...[
          Text(
            '本机打开使用临时副本，修改不会自动写回资料库；退出应用时清理。',
            style: libraryText(context, 13),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              onPressed: _busy ? null : () => _finishOpen(all: true),
              child: Text(
                _openCleanupPending > 0 ? '重试清理本机打开副本' : '结束使用并清理本机打开副本',
              ),
            ),
          ),
        ],
        if (!visiblePreview) const SizedBox(height: 16),
        if (_previewLoading)
          const Text('正在读取预览…')
        else if (_previewFailure != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_previewFailure!.message),
              DesktopButton(
                key: ValueKey('library-file-preview-retry-${widget.fieldKey}'),
                onPressed: () => _turn(_page),
                child: const Text('重试预览'),
              ),
            ],
          ),
        if (_preview case final preview?)
          Offstage(
            key: ValueKey('library-file-canvas-${widget.fieldKey}'),
            offstage:
                _loading ||
                _metadataFailure != null ||
                _previewLoading ||
                _previewFailure != null,
            child: LibraryFilePreviewView(
              key: ValueKey('library-file-preview-${widget.fieldKey}'),
              preview: preview,
              onPage: _turn,
              toolbarLeading: visiblePreview ? toolbar : const [],
            ),
          ),
      ],
    );
  }
}

class LibraryFilePreviewView extends StatefulWidget {
  const LibraryFilePreviewView({
    super.key,
    required this.preview,
    required this.onPage,
    this.toolbarLeading = const [],
  });
  final WorkspaceFilePreview preview;
  final ValueChanged<int> onPage;
  // Owner controls and reader controls share one wrapping toolbar. Historical
  // previews use the same reader without current-file actions.
  final List<Widget> toolbarLeading;
  @override
  State<LibraryFilePreviewView> createState() => _LibraryFilePreviewViewState();
}

class _LibraryFilePreviewViewState extends State<LibraryFilePreviewView> {
  double _zoom = 1;
  bool _text = false;
  MemoryImage? _image;
  void _updateImage() {
    final previous = _image;
    _image = widget.preview.image == null
        ? null
        : MemoryImage(widget.preview.image!);
    if (previous != null) unawaited(previous.evict());
  }

  @override
  void initState() {
    super.initState();
    _updateImage();
  }

  @override
  void didUpdateWidget(LibraryFilePreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.file.ref != widget.preview.file.ref) {
      _zoom = 1;
      _text = false;
    }
    if (!identical(oldWidget.preview.image, widget.preview.image)) {
      _updateImage();
    }
  }

  @override
  void dispose() {
    if (_image != null) unawaited(_image!.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preview, c = UiPalette.of(context);
    final visual =
        p.kind != WorkspaceFilePreviewKind.unsupported &&
        p.kind != WorkspaceFilePreviewKind.text;
    Widget body() {
      if (p.kind == WorkspaceFilePreviewKind.unsupported) {
        return Text(
          '此文件格式暂不支持预览，可另存或用本机程序打开。',
          style: libraryText(context, 14, color: c.muted),
        );
      }
      if (p.kind == WorkspaceFilePreviewKind.text) {
        return SelectableText(
          p.text,
          style: libraryText(context, 14, height: 1.8),
        );
      }
      if (_text) {
        return SelectableText(
          p.text,
          key: const ValueKey('library-file-extracted-text'),
          style: libraryText(context, 14, height: 1.8),
        );
      }
      return LayoutBuilder(
        builder: (context, bounds) {
          final inset = MediaQuery.sizeOf(context).width <= 1300 ? 12.0 : 25.0;
          final available = (bounds.maxWidth - inset * 2).clamp(
            0.0,
            double.infinity,
          );
          final width =
              available.clamp(
                0.0,
                p.file.mediaType == 'image/png' ? 480.0 : 610.0,
              ) *
              _zoom;
          final image = SizedBox(
            width: width,
            child: AspectRatio(
              aspectRatio: p.pixelWidth! / p.pixelHeight!,
              child: Image(
                image: _image!,
                semanticLabel: '${p.file.filename}，第${p.page + 1}页',
                fit: BoxFit.contain,
                frameBuilder: (context, child, frame, synchronous) =>
                    frame != null || synchronous
                    ? child
                    : Center(
                        child: Text(
                          '正在显示文件页面…',
                          style: libraryText(context, 13),
                        ),
                      ),
                errorBuilder: (_, _, _) => const Text('图像无法显示，可重试预览或另存文件。'),
              ),
            ),
          );
          return Container(
            key: const ValueKey('library-file-stage'),
            padding: EdgeInsets.all(inset),
            decoration: BoxDecoration(
              color: c.nav,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.topCenter,
            child: width <= available
                ? image
                : ScrollConfiguration(
                    behavior: const DesktopScrollBehavior(scrollbarGutter: 9),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      primary: false,
                      child: image,
                    ),
                  ),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visual || widget.toolbarLeading.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...widget.toolbarLeading,
              if (visual) ...[
                DesktopButton(
                  key: const ValueKey('library-file-page-back'),
                  kind: DesktopButtonKind.quiet,
                  minimumSize: const Size(32, 32),
                  padding: const EdgeInsets.all(6),
                  tooltip: '上一页',
                  onPressed: p.page > 0
                      ? () => widget.onPage(p.page - 1)
                      : null,
                  child: const PrototypeIcon(
                    PrototypeIconGlyph.back,
                    size: 16,
                    semanticLabel: '上一页',
                  ),
                ),
                Text(
                  '${p.page + 1} / ${p.pageCount}',
                  style: libraryText(context, 13),
                ),
                DesktopButton(
                  key: const ValueKey('library-file-page-next'),
                  kind: DesktopButtonKind.quiet,
                  minimumSize: const Size(32, 32),
                  padding: const EdgeInsets.all(6),
                  tooltip: '下一页',
                  onPressed: p.page + 1 < p.pageCount
                      ? () => widget.onPage(p.page + 1)
                      : null,
                  child: const PrototypeIcon(
                    PrototypeIconGlyph.arrow,
                    size: 16,
                    semanticLabel: '下一页',
                  ),
                ),
                DesktopButton(
                  key: const ValueKey('library-file-zoom-in'),
                  kind: DesktopButtonKind.quiet,
                  minimumSize: const Size(32, 32),
                  padding: const EdgeInsets.all(6),
                  tooltip: '放大',
                  onPressed: _zoom < 2
                      ? () => setState(() => _zoom += .5)
                      : null,
                  child: const PrototypeIcon(
                    PrototypeIconGlyph.plus,
                    size: 16,
                    semanticLabel: '放大',
                  ),
                ),
                DesktopButton(
                  key: const ValueKey('library-file-zoom-out'),
                  kind: DesktopButtonKind.quiet,
                  minimumSize: const Size(32, 32),
                  padding: const EdgeInsets.all(6),
                  tooltip: '缩小',
                  onPressed: _zoom > 1
                      ? () => setState(() => _zoom -= .5)
                      : null,
                  child: Semantics(label: '缩小', child: const Text('−')),
                ),
                if (p.text.isNotEmpty)
                  DesktopButton(
                    key: const ValueKey('library-file-text-mode'),
                    kind: DesktopButtonKind.quiet,
                    fontSize: 13,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    selected: _text,
                    onPressed: () => setState(() => _text = !_text),
                    child: Text(_text ? '文件页面' : '文字内容'),
                  ),
              ],
            ],
          ),
        if (visual || widget.toolbarLeading.isNotEmpty)
          const SizedBox(height: 16),
        body(),
      ],
    );
  }
}

class _FileVersions extends StatefulWidget {
  const _FileVersions({
    required this.source,
    required this.record,
    required this.fieldKey,
    required this.history,
  });
  final WorkspaceSource source;
  final WorkspaceRecordRef record;
  final String fieldKey;
  final WorkspaceFileHistory history;
  @override
  State<_FileVersions> createState() => _FileVersionsState();
}

class _FileVersionsState extends State<_FileVersions> {
  late WorkspaceFileHistory _history = widget.history;
  late int _version = widget.history.current.ref.version;
  int _page = 0, _generation = 0;
  bool _loading = true;
  bool _restoring = false;
  WorkspaceFilePreview? _preview;
  WorkspaceFailure? _failure;
  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read({bool refresh = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      // Keep the same mounted renderer through paging/retry. Offstage below
      // hides the previous page while its replacement is not yet confirmed.
      _failure = null;
    });
    try {
      if (refresh) {
        final history = await widget.source.loadFileHistory(
          widget.record,
          widget.fieldKey,
        );
        if (!mounted || generation != _generation) return;
        _history = history;
        if (!_history.versions.any((v) => v.ref.version == _version)) {
          _version = _history.current.ref.version;
          _page = 0;
        }
      }
      final value = await widget.source.readFilePreview(
        widget.record,
        widget.fieldKey,
        version: _version,
        page: _page,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _preview = value;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '版本预览暂不可用。');
        });
      }
    }
  }

  Future<void> _restore() async {
    if (_restoring) return;
    setState(() => _restoring = true);
    try {
      final restored = await showLibraryFileChange(
        context,
        widget.source,
        widget.record,
        widget.fieldKey,
        _history,
        restoreVersion: _version,
      );
      if (restored == true && mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  WorkspaceFileVersion? get _selectedVersion => _history.versions
      .where((file) => file.ref.version == _version)
      .firstOrNull;

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('文件版本'),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('当前版本：v${_history.current.ref.version}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final file in _history.versions)
              DesktopButton(
                key: ValueKey('library-file-version-${file.ref.version}'),
                selected: _version == file.ref.version,
                kind: DesktopButtonKind.quiet,
                onPressed: () {
                  if (_version == file.ref.version) return;
                  _version = file.ref.version;
                  _page = 0;
                  unawaited(_read());
                },
                child: Text(
                  'v${file.ref.version}${file.ref == _history.current.ref ? ' · 当前' : ' · 历史'}',
                ),
              ),
          ],
        ),
        if (_selectedVersion case final file?) ...[
          const SizedBox(height: 12),
          LibraryFileSummary(
            label:
                '正在查看 · v${file.ref.version}${file.ref == _history.current.ref ? ' · 当前' : ' · 历史'}',
            filename: file.filename,
            mediaType: file.mediaType,
            byteLength: file.byteLength,
            createdAt: file.createdAt,
          ),
        ],
        if (_selectedVersion?.available == false)
          const Text('该版本原文已清理，仅保留版本记录，不能恢复。'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('正在读取版本预览…'),
          ),
        if (_failure != null)
          Text(
            _failure!.message,
            style: libraryText(
              context,
              13,
              color: UiPalette.of(context).danger,
            ),
          ),
        if (_preview case final preview?)
          Offstage(
            key: const ValueKey('library-file-history-canvas'),
            offstage: _loading || _failure != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                LibraryFilePreviewView(
                  preview: preview,
                  onPage: (page) {
                    _page = page;
                    unawaited(_read());
                  },
                ),
              ],
            ),
          ),
      ],
    ),
    actions: [
      DesktopButton(
        onPressed: () => _read(refresh: true),
        child: const Text('重新读取版本'),
      ),
      DesktopButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      if (_version != _history.current.ref.version)
        DesktopButton(
          key: const ValueKey('library-file-restore'),
          kind: DesktopButtonKind.primary,
          onPressed:
              _loading || _restoring || _selectedVersion?.available != true
              ? null
              : _restore,
          child: const Text('恢复此版本'),
        ),
    ],
  );
}
