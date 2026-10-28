import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../ui_palette.dart';
import '../desktop_scroll.dart';
import 'library_file_dialogs.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

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
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LibraryFile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail.version != widget.detail.version ||
        oldWidget.detail.record.ref != widget.detail.record.ref ||
        oldWidget.fieldKey != widget.fieldKey) {
      if (oldWidget.detail.values[oldWidget.fieldKey].toString() !=
          widget.detail.values[widget.fieldKey].toString()) {
        _page = 0;
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
      _history = null;
      _preview = null;
      _metadataFailure = _previewFailure = null;
    });
    try {
      final history = await widget.source.loadFileHistory(
        widget.detail.record.ref,
        widget.fieldKey,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
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
    final generation = ++_generation;
    setState(() {
      _page = page;
      _previewFailure = null;
      _previewLoading = true;
    });
    unawaited(_readPreview(generation));
  }

  Future<void> _modal(Future<void> Function() action) async {
    if (_busy) return;
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
    if (_history == null || _busy || _pendingAction != null) return;
    final operation = workspaceFileOperationId();
    setState(() {
      _busy = true;
      _actionFailure = null;
      _pendingAction = operation;
      _pendingKind = action;
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
      });
      if (result.completed) {
        DesktopFeedback.show(
          context,
          action == WorkspaceFileAction.saveAs
              ? '已另存 ${result.filename}'
              : '已打开 ${result.filename}',
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
        if (failure.code != 'unknown_outcome') _pendingAction = null;
      });
    }
  }

  Future<void> _lookupAction() async {
    if (_pendingAction == null || _busy) return;
    setState(() => _busy = true);
    try {
      final receipt = await widget.source.fileOperationReceipt(_pendingAction!);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pendingAction = null;
        _actionFailure = null;
      });
      if (receipt?.actionCompleted == true) {
        DesktopFeedback.show(
          context,
          _pendingKind == WorkspaceFileAction.saveAs ? '另存操作已完成' : '打开操作已完成',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _actionFailure = const WorkspaceFailure(
            'unknown_outcome',
            '仍无法确认操作结果，请稍后核对。',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), history = _history;
    if (_loading) return const Text('正在读取文件信息…');
    if (_metadataFailure != null || history == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_metadataFailure?.message ?? '文件信息不可用。'),
          DesktopButton(onPressed: _load, child: const Text('重新读取文件')),
        ],
      );
    }
    final blocked = _busy || _pendingAction != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SelectableText(
              history.current.filename,
              key: ValueKey('library-file-filename-${widget.fieldKey}'),
              style: libraryText(context, 13),
            ),
            Text(
              '${history.current.mediaType} · ${workspaceFileSize(history.current.byteLength)} · v${history.current.ref.version}',
              style: libraryText(context, 13, color: c.muted),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DesktopButton(
              key: ValueKey('library-file-replace-${widget.fieldKey}'),
              onPressed: blocked ? null : _replace,
              child: const Text('替换文件'),
            ),
            DesktopButton(
              key: ValueKey('library-file-versions-${widget.fieldKey}'),
              onPressed: blocked ? null : _versions,
              child: const Text('文件版本'),
            ),
            DesktopButton(
              key: ValueKey('library-file-save-${widget.fieldKey}'),
              onPressed: blocked
                  ? null
                  : () => _action(WorkspaceFileAction.saveAs),
              child: const Text('另存为'),
            ),
            DesktopButton(
              key: ValueKey('library-file-open-${widget.fieldKey}'),
              onPressed: blocked
                  ? null
                  : () => _action(WorkspaceFileAction.open),
              child: const Text('用本机程序打开'),
            ),
            DesktopButton(
              key: ValueKey('library-file-preview-refresh-${widget.fieldKey}'),
              onPressed: _previewLoading ? null : () => _turn(_page),
              child: const Text('刷新预览'),
            ),
          ],
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
        const SizedBox(height: 18),
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
            offstage: _previewLoading || _previewFailure != null,
            child: LibraryFilePreviewView(
              key: ValueKey('library-file-preview-${widget.fieldKey}'),
              preview: preview,
              onPage: _turn,
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
  });
  final WorkspaceFilePreview preview;
  final ValueChanged<int> onPage;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DesktopButton(
              key: const ValueKey('library-file-page-back'),
              onPressed: p.page > 0 ? () => widget.onPage(p.page - 1) : null,
              child: const Text('上一页'),
            ),
            Text(
              '${p.page + 1} / ${p.pageCount}',
              style: libraryText(context, 13),
            ),
            DesktopButton(
              key: const ValueKey('library-file-page-next'),
              onPressed: p.page + 1 < p.pageCount
                  ? () => widget.onPage(p.page + 1)
                  : null,
              child: const Text('下一页'),
            ),
            DesktopButton(
              key: const ValueKey('library-file-zoom-in'),
              onPressed: _zoom < 2 ? () => setState(() => _zoom += .5) : null,
              child: const Text('放大'),
            ),
            DesktopButton(
              key: const ValueKey('library-file-zoom-out'),
              onPressed: _zoom > 1 ? () => setState(() => _zoom -= .5) : null,
              child: const Text('缩小'),
            ),
            if (p.text.isNotEmpty)
              DesktopButton(
                key: const ValueKey('library-file-text-mode'),
                onPressed: () => setState(() => _text = !_text),
                child: Text(_text ? '文件页面' : '文字内容'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_text)
          SelectableText(
            p.text,
            key: const ValueKey('library-file-extracted-text'),
            style: libraryText(context, 14, height: 1.8),
          )
        else
          LayoutBuilder(
            builder: (context, bounds) {
              final inset = MediaQuery.sizeOf(context).width <= 1300
                  ? 12.0
                  : 25.0;
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
                        behavior: const DesktopScrollBehavior(
                          scrollbarGutter: 9,
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          primary: false,
                          child: image,
                        ),
                      ),
              );
            },
          ),
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
          SelectableText(file.filename),
          Text('${file.mediaType} · ${workspaceFileSize(file.byteLength)}'),
        ],
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
          onPressed: _loading || _restoring ? null : _restore,
          child: const Text('恢复此版本'),
        ),
    ],
  );
}
