import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../desktop_motion.dart';
import '../desktop_scroll.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_controller.dart';
import 'library_detail.dart';
import 'library_directory_dialog.dart';
import 'library_edit_dialog.dart';
import 'library_credential_editor.dart';
import 'library_history_dialog.dart';
import 'library_credential_lifecycle.dart';
import 'library_recycle.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'library_adoption_dialog.dart';
import 'library_context_region.dart';
import 'library_move_dialog.dart';
import 'library_batch_recycle_dialog.dart';
import 'library_placement_picker.dart';
import 'library_move_action.dart';
import 'library_drag.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    required this.onNavigate,
    this.onModalChanged,
    this.onWorkspaceBack,
    this.workspaceBackLabel = '返回',
    this.workspaceNavigationEnabled = true,
    this.onRetry,
    this.filePicker,
    this.credentialPicker,
  });
  final VoidCallback? onWorkspaceBack;
  final String workspaceBackLabel;
  final bool workspaceNavigationEnabled;
  final LibraryController controller;
  final void Function(WorkspacePage, String) onNavigate;
  final ValueChanged<bool>? onModalChanged;
  final VoidCallback? onRetry;
  final WorkspaceFilePicker? filePicker;
  final WorkspaceCredentialPicker? credentialPicker;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _list = ScrollController(), _detailScroll = ScrollController();
  final _directoryScroll = ScrollController();
  final _directoryViewport = GlobalKey(), _recordViewport = GlobalKey();
  final _collapsed = <String>{};
  LibraryDragData? _drag;
  bool _routingDrag = false;
  LibraryDropHint? _dropHint;
  Offset? _dragPointer;
  Timer? _expandTimer;
  String? _expanding;
  late final _dragRegistry = LibraryDragRegistry(
    onHover: _dragHover,
    onOutside: _dragOutside,
  );
  late final _dragScroll = LibraryDragAutoScroller(_dragScrolled);
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _workspaceFocus = FocusNode(debugLabel: 'library-workspace');
  int _focusRequest = 0, _viewReset = 0;
  bool _reading = false, _recyclePage = false, _placing = false;
  WorkspaceRecordRef? _lastSelection;
  LibraryController get model => widget.controller;
  bool get _canMove =>
      model.source is WorkspaceLibraryMove &&
      (model.source as WorkspaceLibraryMove).libraryMoveSupported;
  bool get _canRecycle =>
      model.source is WorkspaceLibraryRecycle &&
      (model.source as WorkspaceLibraryRecycle).libraryRecycleSupported;
  bool get _canManage => _canMove || _canRecycle;
  bool get _canOrder =>
      _canMove && (model.source as WorkspaceLibraryMove).libraryOrderSupported;

  Rect? _viewport(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
  }

  LibraryDragData _dragData(WorkspaceLibrarySelection selection) =>
      LibraryDragData(
        model.source,
        selection,
        model.catalog!,
        model.results?.items ?? const [],
      );
  void _beginDrag(LibraryDragData data) {
    if (!model.selectionAvailable || _placing || _drag != null) {
      data.cancelled = true;
      return;
    }
    _workspaceFocus.requestFocus();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_dragEvents);
    _routingDrag = true;
    setState(() {
      _drag = data;
      _dropHint = null;
    });
  }

  // Route from the workspace: a virtualized source row may be disposed while
  // the pointer scrolls through a long list. Release must still resolve once.
  void _dragEvents(PointerEvent event) {
    if (_drag == null || event.pointer != _drag!.pointer) return;
    if (event is PointerMoveEvent) _moveDragPointer(event.position);
    if (event is PointerUpEvent) _endDrag(event.position);
    if (event is PointerCancelEvent) _cancelDrag(inject: false);
  }

  void _clearDrag({bool paint = true}) {
    if (_routingDrag) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_dragEvents);
      _routingDrag = false;
    }
    _dragScroll.stop();
    _expandTimer?.cancel();
    _expandTimer = null;
    _expanding = null;
    _dragRegistry.clear(paint: paint);
    void clear() {
      _drag = null;
      _dropHint = null;
      _dragPointer = null;
    }

    if (paint && mounted && (_drag != null || _dropHint != null)) {
      setState(clear);
    } else {
      clear();
    }
  }

  void _cancelDrag({bool inject = true}) {
    final data = _drag;
    if (data == null) return;
    data.cancelled = true;
    if (inject && data.pointer != null) {
      GestureBinding.instance.cancelPointer(data.pointer!);
    }
    _clearDrag();
  }

  void _endDrag(Offset pointer) {
    final data = _drag;
    if (data == null) return;
    final placement = _dragRegistry.placementAt(data, pointer);
    _clearDrag();
    if (placement != null && mounted && model.selectionAvailable && !_placing) {
      unawaited(_place(data.selection, placement: placement));
    }
  }

  void _dragOutside() {
    _expandTimer?.cancel();
    _expandTimer = null;
    _expanding = null;
    if (_dropHint != null && mounted) setState(() => _dropHint = null);
  }

  void _dragHover(Offset point, LibraryDropHint hint, String? directory) {
    if (_drag == null) return;
    if (!hint.sameAs(_dropHint)) setState(() => _dropHint = hint);
    if (directory != null &&
        hint.allowed &&
        hint.zone == LibraryDropZone.into &&
        _collapsed.contains(directory)) {
      if (_expanding == directory) return;
      _expandTimer?.cancel();
      _expanding = directory;
      _expandTimer = Timer(const Duration(milliseconds: 650), () {
        if (!mounted || _drag == null) return;
        setState(() => _collapsed.remove(directory));
        _expanding = null;
        _expandTimer = null;
        _dragScrolled();
      });
    } else {
      _expandTimer?.cancel();
      _expandTimer = null;
      _expanding = null;
    }
  }

  void _dragScrolled() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _drag != null && _dragPointer != null) {
      _dragRegistry.update(_drag!, _dragPointer!);
    }
  });
  void _moveDragPointer(Offset point) {
    final data = _drag;
    if (data == null) return;
    _dragPointer = point;
    _dragRegistry.update(data, point);
    for (final viewport in [
      (_directoryViewport, _directoryScroll),
      (_recordViewport, _list),
    ]) {
      final bounds = _viewport(viewport.$1);
      if (bounds?.contains(point) == true) {
        _dragScroll.update(viewport.$2, bounds!, point);
        return;
      }
    }
    _dragScroll.stop();
  }

  Widget _dragDirectory(WorkspaceDirectory directory, Widget child) {
    if (!_canMove || model.catalog == null) return child;
    final real = !libraryVirtualDirectoryIds.contains(directory.id);
    final data = real
        ? _dragData(model.selectionForDirectory(directory.id))
        : null;
    return LibraryDropRegion(
      key: ValueKey('library-directory-drop-${directory.id}'),
      registry: _dragRegistry,
      origin: model.source,
      enabled: model.selectionAvailable && !_placing,
      viewport: () => _viewport(_directoryViewport),
      directoryId: real ? directory.id : null,
      resolve: (data, fraction) => libraryDirectoryDrop(
        data,
        directory,
        model.catalog!,
        fraction,
        canOrder: _canOrder,
      ),
      child: data == null
          ? child
          : LibraryDragHandle(
              data: data,
              enabled: model.selectionAvailable && !_placing,
              onStart: () => _beginDrag(data),
              child: child,
            ),
    );
  }

  Widget _dragRecord(WorkspaceRecordSummary record, Widget child) {
    if (!_canMove || model.catalog == null) return child;
    final data = _dragData(model.selectionForRecord(record.ref));
    return LibraryDropRegion(
      key: ValueKey('library-record-drop-${record.ref.key}'),
      registry: _dragRegistry,
      origin: model.source,
      enabled: model.selectionAvailable && !_placing,
      viewport: () => _viewport(_recordViewport),
      resolve: (data, fraction) => libraryRecordDrop(
        data,
        record,
        model.catalog!,
        fraction,
        manual: _canOrder && model.query.sort == WorkspaceSort.manual,
      ),
      child: LibraryDragHandle(
        data: data,
        enabled: model.selectionAvailable && !_placing,
        onStart: () => _beginDrag(data),
        child: child,
      ),
    );
  }

  Future<void> _manage(
    WorkspaceLibrarySelection selection, {
    required bool moving,
  }) async {
    if (_placing || !model.selectionAvailable) {
      DesktopFeedback.show(context, '资料正在更新，请稍后再试。');
      return;
    }
    setState(() => _placing = true);
    widget.onModalChanged?.call(true);
    try {
      final Object? receipt;
      if (moving) {
        receipt = await showLibraryMove(context, model.source, selection);
      } else if (selection.directoryIds.isEmpty &&
          selection.records.length == 1) {
        // Retain the existing single-record lifecycle, including its individual
        // restore/purge actions. Only an actual group becomes one recycle batch.
        final current = await model.source.readDetail(selection.records.single);
        if (!mounted) return;
        receipt = await showLibraryRecycle(
          context,
          model.source,
          current: current,
        );
      } else {
        receipt = await showLibraryBatchRecycle(
          context,
          model.source,
          selection: selection,
        );
      }
      if (!mounted || receipt == null) return;
      model.cancelSelection();
      await model.load(model.query);
      if (mounted) {
        DesktopFeedback.show(context, moving ? '已移动所选内容' : '所选内容已移到回收站');
      }
    } on WorkspaceFailure catch (e) {
      if (mounted) DesktopFeedback.show(context, e.message);
    } finally {
      widget.onModalChanged?.call(false);
      if (mounted) {
        setState(() => _placing = false);
        _workspaceFocus.requestFocus();
      }
    }
  }

  Future<void> _place(
    WorkspaceLibrarySelection selection, {
    WorkspaceLibraryPlacement? placement,
  }) async {
    if (_placing || !model.selectionAvailable) return;
    setState(() => _placing = true);
    widget.onModalChanged?.call(true);
    try {
      final target =
          placement ??
          await showLibraryPlacementPicker(context, model.source, selection);
      if (!mounted || target == null) return;
      final receipt = await performLibraryPlacement(
        context,
        model.source,
        selection,
        target,
      );
      if (!mounted || receipt == null) return;
      model.cancelSelection();
      if (target.position != null && target.position!.kind != 'directory') {
        await model.apply(model.query.copyWith(sort: WorkspaceSort.manual));
      } else {
        await model.load(model.query);
      }
      if (mounted) {
        DesktopFeedback.show(
          context,
          target.position == null ? '已移动所选内容' : '已调整顺序',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
      if (mounted) {
        setState(() => _placing = false);
        _workspaceFocus.requestFocus();
      }
    }
  }

  Future<void> _recordContext(
    WorkspaceRecordSummary record,
    Offset position,
  ) async {
    final selection = model.selectionForRecord(record.ref);
    final action = await showLibraryContextMenu<String>(context, position, [
      const PopupMenuItem(value: 'open', child: Text('打开资料')),
      if (_canMove) const PopupMenuItem(value: 'move', child: Text('移动')),
      if (_canOrder) const PopupMenuItem(value: 'order', child: Text('调整顺序')),
      if (_canRecycle)
        const PopupMenuItem(value: 'recycle', child: Text('移到回收站')),
      const PopupMenuItem(value: 'select', child: Text('选择或取消选择')),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'open':
        await model.select(record.ref);
      case 'move':
        await _manage(selection, moving: true);
      case 'order':
        await _place(selection);
      case 'recycle':
        await _manage(selection, moving: false);
      case 'select':
        model.toggleRecord(record.ref);
    }
  }

  Future<void> _unfiledContext(Offset position) async {
    final action = await showLibraryContextMenu<String>(context, position, [
      const PopupMenuItem(value: 'recycle', child: Text('将未分类资料移到回收站')),
    ]);
    if (!mounted || action != 'recycle') return;
    final records = <WorkspaceRecordRef>[];
    var offset = 0;
    while (true) {
      final result = await model.source.queryRecords(
        WorkspaceQuery(directoryId: 'unfiled', offset: offset, limit: 100),
      );
      records.addAll(result.items.map((r) => r.ref));
      offset += result.items.length;
      if (offset >= result.total || result.items.isEmpty) break;
    }
    if (mounted && records.isNotEmpty) {
      await _manage(WorkspaceLibrarySelection(records: records), moving: false);
    }
  }

  Future<void> _directoryContext(
    WorkspaceDirectory directory,
    Offset position,
  ) async {
    final selection = model.selectionForDirectory(directory.id);
    final action = await showLibraryContextMenu<String>(context, position, [
      const PopupMenuItem(value: 'child', child: Text('新建子目录')),
      PopupMenuItem(value: 'edit', child: Text(_canMove ? '重命名' : '重命名或移动')),
      if (_canMove) const PopupMenuItem(value: 'move', child: Text('移动')),
      if (_canOrder) const PopupMenuItem(value: 'order', child: Text('调整顺序')),
      if (_canRecycle)
        const PopupMenuItem(value: 'recycle', child: Text('移到回收站')),
      const PopupMenuItem(value: 'select', child: Text('选择或取消选择')),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'child':
        await _changeDirectory(
          WorkspaceDirectoryAction.create,
          parent: directory.id,
        );
      case 'edit':
        await _changeDirectory(
          WorkspaceDirectoryAction.update,
          directory: directory,
        );
      case 'move':
        await _manage(selection, moving: true);
      case 'order':
        await _place(selection);
      case 'recycle':
        await _manage(selection, moving: false);
      case 'select':
        model.toggleDirectory(directory.id);
    }
  }

  Widget _selectionToolbar() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!model.selecting)
              DesktopButton(
                key: const ValueKey('library-select-mode'),
                kind: DesktopButtonKind.quiet,
                onPressed: model.selectionAvailable
                    ? model.beginSelection
                    : null,
                child: const Text('多选'),
              )
            else ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  '已选 ${model.selectedCount} 项',
                  key: const ValueKey('library-selection-count'),
                ),
              ),
              DesktopButton(
                key: const ValueKey('library-select-page'),
                kind: DesktopButtonKind.quiet,
                onPressed: model.selectionAvailable
                    ? model.selectDisplayedRecords
                    : null,
                child: const Text('全选本页资料'),
              ),
              if (_canMove)
                DesktopButton(
                  key: const ValueKey('library-selection-move'),
                  onPressed: model.selectionAvailable && model.selectedCount > 0
                      ? () => _manage(model.selectedBatch, moving: true)
                      : null,
                  child: const Text('移动'),
                ),
              if (_canRecycle)
                DesktopButton(
                  key: const ValueKey('library-selection-recycle'),
                  onPressed: model.selectionAvailable && model.selectedCount > 0
                      ? () => _manage(model.selectedBatch, moving: false)
                      : null,
                  child: const Text('移到回收站'),
                ),
              if (_canOrder)
                DesktopButton(
                  key: const ValueKey('library-selection-order'),
                  onPressed:
                      model.selectionAvailable &&
                          model.selectedCount > 0 &&
                          !_placing
                      ? () => _place(model.selectedBatch)
                      : null,
                  child: const Text('调整顺序'),
                ),
              DesktopButton(
                key: const ValueKey('library-selection-cancel'),
                kind: DesktopButtonKind.quiet,
                onPressed: model.cancelSelection,
                child: const Text('取消多选'),
              ),
            ],
          ],
        ),
        if (model.sortPreferenceNotice != null)
          Semantics(liveRegion: true, child: Text(model.sortPreferenceNotice!)),
        if (model.selectionNotice != null)
          Semantics(
            liveRegion: true,
            child: Text(
              model.selectionNotice!,
              key: const ValueKey('library-selection-notice'),
            ),
          ),
      ],
    ),
  );
  @override
  void initState() {
    super.initState();
    _search.text = model.query.keyword;
    _searchFocus.addListener(_searchFocusChanged);
    _lastSelection = model.selection;
    model.addListener(_changed);
    _focusRequest = model.searchFocusRequest;
    _viewReset = model.viewReset;
    if (_focusRequest > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
    _list.addListener(() {
      model.scrollOffset = _list.offset;
    });
  }

  @override
  void dispose() {
    _drag?.cancelled = true;
    _clearDrag(paint: false);
    model.removeListener(_changed);
    _list.dispose();
    _directoryScroll.dispose();
    _detailScroll.dispose();
    _search.dispose();
    _searchFocus.removeListener(_searchFocusChanged);
    _searchFocus.dispose();
    _workspaceFocus.dispose();
    super.dispose();
  }

  void _searchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    if (_drag != null && model.loadState == WorkspaceLoad.loading) {
      _cancelDrag();
    }
    if (_search.text != model.query.keyword &&
        !_search.value.composing.isValid) {
      _search.text = model.query.keyword;
    }
    if (_viewReset != model.viewReset) {
      _viewReset = model.viewReset;
      _recyclePage = _reading = false;
    }
    setState(() {});
    if (_lastSelection != model.selection) {
      _lastSelection = model.selection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detailScroll.hasClients) _detailScroll.jumpTo(0);
      });
    }
    if (_focusRequest != model.searchFocusRequest) {
      _focusRequest = model.searchFocusRequest;
      setState(() {
        _recyclePage = _reading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_list.hasClients) return;
      final target = model.scrollOffset.clamp(
        0,
        _list.position.maxScrollExtent,
      );
      if ((_list.offset - target).abs() > .5) _list.jumpTo(target.toDouble());
    });
  }

  Future<void> _edit({bool create = false}) async {
    if (model.loadState == WorkspaceLoad.loading) return;
    widget.onModalChanged?.call(true);
    try {
      final detail = model.detail;
      WorkspaceRecordRef? ref;
      if (!create &&
          detail?.record.ref.kind == WorkspaceRecordKind.credential) {
        final catalog = await model.source.loadCatalog();
        if (!mounted) return;
        ref = await showLibraryCredentialEditor(
          context,
          model.source,
          catalog,
          ref: detail!.record.ref,
          picker: widget.credentialPicker,
        );
      } else {
        ref = await showLibraryEditor(
          context,
          model,
          detail: create ? null : detail,
          filePicker: widget.filePicker,
          credentialPicker: widget.credentialPicker,
          onOpenPlugins: () =>
              widget.onNavigate(WorkspacePage.settings, 'plugins'),
        );
      }
      if (!mounted || ref == null) return;
      await model.openRelated(ref, rememberOrigin: create);
      if (mounted) {
        DesktopFeedback.show(
          context,
          model.detail?.record.ref == ref
              ? (create ? '已添加资料' : '已保存资料')
              : '操作已提交，当前资料暂不可用，请查看读取结果。',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
      if (mounted) _workspaceFocus.requestFocus();
    }
  }

  Future<void> _history() async {
    final ref = model.detail?.record.ref;
    if (ref == null) return;
    widget.onModalChanged?.call(true);
    try {
      final restored = ref.kind == WorkspaceRecordKind.credential
          ? await showCredentialMaterials(context, model.source, ref)
          : await showLibraryHistory(context, model.source, ref);
      if (!mounted || restored != true) return;
      await model.openRelated(ref, rememberOrigin: false);
      if (mounted) {
        DesktopFeedback.show(
          context,
          model.detail?.record.ref == ref
              ? '已恢复为新版本'
              : '恢复已提交，当前资料暂不可用，请查看读取结果。',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _adopt() async {
    final ref = model.detail?.record.ref;
    if (ref == null || ref.kind != WorkspaceRecordKind.information) return;
    widget.onModalChanged?.call(true);
    try {
      final adopted = await showLibraryAdoption(context, model.source, ref);
      if (mounted && adopted != null) {
        await model.openRelated(adopted, rememberOrigin: false);
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _recycleCurrent() async {
    final detail = model.detail;
    if (detail == null) return;
    if (_canRecycle) {
      return _manage(
        WorkspaceLibrarySelection(records: [detail.record.ref]),
        moving: false,
      );
    }
    widget.onModalChanged?.call(true);
    try {
      final receipt = await showLibraryRecycle(
        context,
        model.source,
        current: detail,
      );
      if (!mounted || receipt == null) return;
      await model.load(model.query);
      if (mounted) DesktopFeedback.show(context, '已移到回收站');
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  void _toggleReading() {
    _reading = !_reading;
    _changed();
    // Reading removes the search field (and may remove the focused button).
    // Keep subsequent search/escape shortcuts inside this workspace scope.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _workspaceFocus.requestFocus();
    });
  }

  Future<void> _changeDirectory(
    WorkspaceDirectoryAction action, {
    WorkspaceDirectory? directory,
    String? parent,
  }) async {
    if (model.loadState == WorkspaceLoad.loading) return;
    widget.onModalChanged?.call(true);
    try {
      final saved = await showLibraryDirectoryEditor(
        context,
        model,
        action: action,
        directory: directory,
        initialParent: parent,
      );
      if (saved && mounted) {
        DesktopFeedback.show(
          context,
          action == WorkspaceDirectoryAction.delete
              ? model.source is WorkspaceLibraryRecycle &&
                        (model.source as WorkspaceLibraryRecycle)
                            .libraryRecycleSupported
                    ? '目录和内容已移到回收站'
                    : '已删除空目录'
              : '目录已保存',
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Widget _directory(
    BuildContext context,
    WorkspaceDirectory directory,
    LibraryMetrics metrics,
  ) {
    final real = !libraryVirtualDirectoryIds.contains(directory.id);
    final selected = model.selecting && real
        ? model.directoryIsSelected(directory.id)
        : (model.query.directoryId ?? 'all') == directory.id;
    final path = libraryDirectoryAncestors(model.catalog!, directory);
    final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
    final count = '${model.catalog?.directoryCounts[directory.id] ?? 0}';
    void activate() {
      if (model.selecting && real) {
        model.toggleDirectory(directory.id);
      } else if (directory.id == 'all') {
        model.showAll();
      } else {
        model.apply(model.query.copyWith(directoryId: directory.id));
      }
    }

    final content = LibraryContextRegion(
      enabled:
          _canManage &&
          model.selectionAvailable &&
          !_placing &&
          (real || directory.id == 'unfiled'),
      onActivate: activate,
      onContext: (position) async {
        if (real) await _directoryContext(directory, position);
        if (directory.id == 'unfiled') await _unfiledContext(position);
      },
      builder: (activate) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          children: [
            if (model.selecting && real)
              Checkbox(
                value: model.directoryIsSelected(directory.id),
                onChanged: model.selectionAvailable ? (_) => activate() : null,
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final desiredIndent =
                      (path.length - 1).clamp(0, 3) * (largeText ? 10.0 : 22.0);
                  final room = (bounds.maxWidth - 96).clamp(
                    0.0,
                    double.infinity,
                  );
                  final indent = desiredIndent.clamp(0.0, room);
                  return DesktopButton(
                    key: ValueKey('library-directory-${directory.id}'),
                    tooltip: path.map((d) => d.name).join(' › '),
                    selected: selected,
                    kind: DesktopButtonKind.quiet,
                    onPressed: model.selectionAvailable ? activate : null,
                    fontSize: metrics.compact ? 13 : 14,
                    padding: EdgeInsets.fromLTRB(10 + indent, 8, 10, 8),
                    minimumSize: const Size(0, 39),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        PrototypeIcon(
                          directory.id == 'all'
                              ? PrototypeIconGlyph.grid
                              : PrototypeIconGlyph.folder,
                          size: 17,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                directory.name,
                                style: libraryText(
                                  context,
                                  metrics.compact ? 13 : 14,
                                  color: selected
                                      ? UiPalette.of(context).accent
                                      : UiPalette.of(context).ink,
                                  weight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                                maxLines: largeText ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (largeText)
                                Text(
                                  '$count 项',
                                  style: libraryText(
                                    context,
                                    12,
                                    color: UiPalette.of(context).muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (_canMove &&
                            real &&
                            model.catalog!.directories.any(
                              (d) => d.parentId == directory.id,
                            ))
                          SizedBox(
                            width: 24,
                            child: IconButton(
                              key: ValueKey(
                                'library-directory-toggle-${directory.id}',
                              ),
                              padding: EdgeInsets.zero,
                              tooltip: _collapsed.contains(directory.id)
                                  ? '展开${directory.name}'
                                  : '收起${directory.name}',
                              onPressed: () {
                                if (HardwareKeyboard
                                    .instance
                                    .isControlPressed) {
                                  return;
                                }
                                setState(() {
                                  if (!_collapsed.add(directory.id)) {
                                    _collapsed.remove(directory.id);
                                  }
                                });
                              },
                              icon: Icon(
                                _collapsed.contains(directory.id)
                                    ? Icons.chevron_right
                                    : Icons.expand_more,
                                size: 17,
                              ),
                            ),
                          ),
                        if (!largeText) ...[
                          const SizedBox(width: 5),
                          Text(
                            count,
                            style: libraryText(
                              context,
                              12,
                              color: UiPalette.of(context).muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    return _dragDirectory(directory, content);
  }

  Widget _directoryMenu(WorkspaceDirectory directory) => DesktopSelect<String>(
    key: ValueKey('library-directory-actions-${directory.id}'),
    compact: true,
    quiet: true,
    triggerLabel: Semantics(
      label: '目录操作：${directory.name}',
      child: const PrototypeIcon(PrototypeIconGlyph.more, size: 16),
    ),
    items: [
      const DropdownMenuItem(value: 'child', child: Text('新建子目录')),
      DropdownMenuItem(value: 'edit', child: Text(_canMove ? '重命名' : '重命名或移动')),
      if (_canMove) const DropdownMenuItem(value: 'move', child: Text('移动')),
      if (_canOrder)
        const DropdownMenuItem(value: 'order', child: Text('调整顺序')),
      DropdownMenuItem(
        value: 'delete',
        child: Text(_canRecycle ? '移到回收站' : '删除空目录'),
      ),
    ],
    onChanged: model.loadState == WorkspaceLoad.loading
        ? null
        : (action) {
            switch (action) {
              case 'child':
                _changeDirectory(
                  WorkspaceDirectoryAction.create,
                  parent: directory.id,
                );
              case 'edit':
                _changeDirectory(
                  WorkspaceDirectoryAction.update,
                  directory: directory,
                );
              case 'move':
                _manage(
                  model.selectionForDirectory(directory.id),
                  moving: true,
                );
              case 'order':
                _place(model.selectionForDirectory(directory.id));
              case 'delete':
                _changeDirectory(
                  WorkspaceDirectoryAction.delete,
                  directory: directory,
                );
            }
          },
  );

  Widget _side(BuildContext context, LibraryMetrics metrics) {
    final c = UiPalette.of(context), catalog = model.catalog;
    final current = catalog?.directories
        .where(
          (d) =>
              d.id == model.query.directoryId &&
              !['all', 'unfiled'].contains(d.id),
        )
        .firstOrNull;
    final directories = catalog == null
        ? <WorkspaceDirectory>[]
        : [
            if (!catalog.directories.any((d) => d.id == 'all'))
              const WorkspaceDirectory('all', '全部资料'),
            ...libraryVisibleDirectoryTree(catalog, _collapsed).where(
              (d) =>
                  d.id != 'unfiled' ||
                  (catalog.directoryCounts['unfiled'] ?? 0) > 0,
            ),
            if (!catalog.directories.any((d) => d.id == 'unfiled') &&
                (catalog.directoryCounts['unfiled'] ?? 0) > 0)
              const WorkspaceDirectory('unfiled', '未分类'),
          ];
    final decorations = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 18, 0, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 33),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '资料目录',
                  style: libraryText(
                    context,
                    15,
                    color: c.ink,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              if (current != null) _directoryMenu(current),
            ],
          ),
        ),
      ),
      if (catalog != null) ...[
        DesktopButton(
          key: const ValueKey('library-directory-create'),
          kind: DesktopButtonKind.quiet,
          alignment: Alignment.centerLeft,
          minimumSize: const Size(0, 39),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          leadingGap: 10,
          leading: const PrototypeIcon(PrototypeIconGlyph.plus, size: 17),
          onPressed: model.loadState == WorkspaceLoad.loading
              ? null
              : () => _changeDirectory(
                  WorkspaceDirectoryAction.create,
                  parent: ['all', 'unfiled'].contains(model.query.directoryId)
                      ? null
                      : model.query.directoryId,
                ),
          child: Text('新建目录', style: libraryText(context, 13, color: c.muted)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
          child: Divider(height: 1, color: c.line),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '标签',
                  key: const ValueKey('library-tag-label'),
                  style: libraryText(
                    context,
                    15,
                    color: c.ink,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              DesktopButton(
                key: const ValueKey('library-tags-manage'),
                kind: DesktopButtonKind.quiet,
                fontSize: 13,
                minimumSize: const Size(0, 28.8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                onPressed: () =>
                    widget.onNavigate(WorkspacePage.settings, 'labels'),
                child: const Text('管理'),
              ),
            ],
          ),
        ),
        Padding(
          key: const ValueKey('library-tag-cloud'),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 13),
          child: Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final tag in catalog.tags.take(7))
                LibraryTag(
                  tag.name,
                  key: ValueKey('library-sidebar-tag-${tag.id}'),
                  selected: model.query.tagId == tag.id,
                  onPressed: () => model.apply(
                    model.query.copyWith(
                      tagId: tag.id,
                      clearTag: model.query.tagId == tag.id,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ];
    final indices = <Key, int>{
      for (var i = 0; i < directories.length; i++)
        ValueKey('library-directory-row-${directories[i].id}'): i + 1,
      for (var i = 0; i < decorations.length; i++)
        if (decorations[i].key != null)
          decorations[i].key!: i == 0 ? 0 : directories.length + i,
    };
    return Container(
      key: const ValueKey('library-directory-pane'),
      width: metrics.directoryWidth,
      decoration: BoxDecoration(
        color: c.rail,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          Expanded(
            child: KeyedSubtree(
              key: _directoryViewport,
              child: ListView.builder(
                addAutomaticKeepAlives: false,
                controller: _directoryScroll,
                key: const ValueKey('library-directory-scroll'),
                padding: const EdgeInsets.fromLTRB(12, 20, 10, 18),
                itemCount: directories.length + decorations.length,
                findChildIndexCallback: (key) => indices[key],
                itemBuilder: (context, index) {
                  if (index == 0) return decorations[0];
                  if (index <= directories.length) {
                    final directory = directories[index - 1];
                    return KeyedSubtree(
                      key: ValueKey('library-directory-row-${directory.id}'),
                      child: _directory(context, directory, metrics),
                    );
                  }
                  return decorations[index - directories.length];
                },
              ),
            ),
          ),
          Container(
            key: const ValueKey('library-side-footer'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 3),
                DesktopButton(
                  key: const ValueKey('library-open-recycle'),
                  kind: DesktopButtonKind.quiet,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  minimumSize: const Size(0, 39),
                  alignment: Alignment.centerLeft,
                  onPressed: () => setState(() {
                    _recyclePage = true;
                    _reading = false;
                  }),
                  child: Row(
                    children: [
                      const PrototypeIcon(PrototypeIconGlyph.trash, size: 17),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '回收站',
                          style: libraryText(
                            context,
                            metrics.compact ? 13 : 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${catalog?.recycledCount ?? 0}',
                        style: libraryText(context, 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(9, 7, 9, 0),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        ExcludeSemantics(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: c.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            model.source is WorkspaceStorageLocation
                                ? (model.source as WorkspaceStorageLocation)
                                      .storageDescription
                                : '资料保存在本机',
                            key: const ValueKey('library-local-storage-note'),
                            style: libraryText(context, 12, color: c.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _directoryName => model.query.directoryId == 'unfiled'
      ? '未分类'
      : model.catalog?.directories
                .where((d) => d.id == (model.query.directoryId ?? 'all'))
                .firstOrNull
                ?.name ??
            '全部资料';
  Widget _header(BuildContext context) {
    final c = UiPalette.of(context),
        query = model.query,
        catalog = model.catalog;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _directoryName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: libraryText(
                    context,
                    17,
                    height: 1.5,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              DesktopButton(
                key: const ValueKey('library-create'),
                kind: DesktopButtonKind.quiet,
                onPressed:
                    catalog == null || model.loadState == WorkspaceLoad.loading
                    ? null
                    : () => _edit(create: true),
                minimumSize: const Size(30, 36),
                padding: const EdgeInsets.all(6),
                tooltip: '添加资料',
                child: const PrototypeIcon(PrototypeIconGlyph.plus, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Container(
            key: const ValueKey('library-search-frame'),
            height: 39 * MediaQuery.textScalerOf(context).scale(1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.paper,
              border: Border.all(
                color: _searchFocus.hasFocus ? c.accent : c.line,
              ),
              borderRadius: BorderRadius.circular(7),
              boxShadow: _searchFocus.hasFocus
                  ? [BoxShadow(color: c.selected, spreadRadius: 2)]
                  : null,
            ),
            child: Row(
              children: [
                const PrototypeIcon(PrototypeIconGlyph.search, size: 16),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    key: const ValueKey('library-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    onChanged: (s) => model.apply(query.copyWith(keyword: s)),
                    style: libraryText(context, 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      hintText: '搜索名称、用途、标签',
                    ),
                  ),
                ),
                Text(
                  Theme.of(context).platform == TargetPlatform.macOS
                      ? '⌘ K'
                      : 'Ctrl K',
                  style: libraryText(context, 11, color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: DesktopSelect<String?>(
                  key: const ValueKey('library-type-filter'),
                  value: query.typeId,
                  highlighted: query.typeId != null,
                  compact: true,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部类型')),
                    for (final type in catalog?.types ?? <WorkspaceType>[])
                      DropdownMenuItem(value: type.id, child: Text(type.name)),
                  ],
                  onChanged: (v) => model.apply(
                    query.copyWith(typeId: v, clearType: v == null),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DesktopSelect<String?>(
                  key: const ValueKey('library-tag-filter'),
                  value: query.tagId,
                  highlighted: query.tagId != null,
                  compact: true,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部标签')),
                    for (final tag in catalog?.tags ?? <WorkspaceTag>[])
                      DropdownMenuItem(value: tag.id, child: Text(tag.name)),
                  ],
                  onChanged: (v) => model.apply(
                    query.copyWith(tagId: v, clearTag: v == null),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 33),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      model.loadState == WorkspaceLoad.loading
                          ? '正在更新…'
                          : '${model.results?.total ?? 0} 项',
                      style: libraryText(context, 12, color: c.muted),
                    ),
                  ),
                  DesktopSelect<WorkspaceGrouping>(
                    key: const ValueKey('library-group'),
                    value: query.grouping,
                    compact: true,
                    quiet: true,
                    toolbar: true,
                    leading: const PrototypeIcon(
                      PrototypeIconGlyph.grid,
                      size: 14,
                    ),
                    triggerLabel: const Text('分组'),
                    items: [
                      for (final g in WorkspaceGrouping.values)
                        DropdownMenuItem(value: g, child: Text(_groupName(g))),
                    ],
                    onChanged: (v) => model.apply(query.copyWith(grouping: v)),
                  ),
                  const SizedBox(width: 5),
                  DesktopSelect<WorkspaceSort>(
                    key: const ValueKey('library-sort'),
                    value: query.sort,
                    compact: true,
                    quiet: true,
                    toolbar: true,
                    leading: const PrototypeIcon(
                      PrototypeIconGlyph.sort,
                      size: 14,
                    ),
                    triggerLabel: const Text('排序'),
                    items: [
                      const DropdownMenuItem(
                        value: WorkspaceSort.updated,
                        child: Text('最近更新优先'),
                      ),
                      const DropdownMenuItem(
                        value: WorkspaceSort.name,
                        child: Text('按名称'),
                      ),
                      if (_canOrder)
                        const DropdownMenuItem(
                          value: WorkspaceSort.manual,
                          child: Text('手动顺序'),
                        ),
                    ],
                    onChanged: (v) => model.apply(query.copyWith(sort: v)),
                  ),
                ],
              ),
            ),
          ),
          if (_canManage) _selectionToolbar(),
        ],
      ),
    );
  }

  String _groupName(WorkspaceGrouping g) => switch (g) {
    WorkspaceGrouping.none => '不分组',
    WorkspaceGrouping.type => '按类型',
    WorkspaceGrouping.directory => '按目录',
  };
  String _sortName(WorkspaceSort sort) => switch (sort) {
    WorkspaceSort.updated => '最近更新优先',
    WorkspaceSort.name => '按名称',
    WorkspaceSort.manual => '手动顺序',
  };
  String _groupKey(WorkspaceRecordSummary r) => switch (model.query.grouping) {
    WorkspaceGrouping.none => '',
    WorkspaceGrouping.type => r.type.id,
    WorkspaceGrouping.directory => r.directoryId ?? 'unfiled',
  };
  String _groupLabel(WorkspaceRecordSummary r) =>
      switch (model.query.grouping) {
        WorkspaceGrouping.none => '',
        WorkspaceGrouping.type => r.type.name,
        WorkspaceGrouping.directory =>
          model.query.sort == WorkspaceSort.manual && model.catalog != null
              ? directoryPath(model.catalog!, r.directoryId)
              : model.catalog?.directories
                        .where((d) => d.id == (r.directoryId ?? 'unfiled'))
                        .firstOrNull
                        ?.name ??
                    '未分类',
      };

  Widget _record(BuildContext context, WorkspaceRecordSummary r) {
    final c = UiPalette.of(context),
        selected = model.selecting
            ? model.recordIsSelected(r.ref)
            : model.selection == r.ref;
    final content = LibraryContextRegion(
      enabled: _canManage && model.selectionAvailable && !_placing,
      onActivate: () =>
          model.selecting ? model.toggleRecord(r.ref) : model.select(r.ref),
      onContext: (position) => _recordContext(r, position),
      builder: (activate) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: DesktopButton(
          key: ValueKey('library-record-${r.ref.key}'),
          radius: 8,
          selectedBorder: true,
          kind: DesktopButtonKind.quiet,
          selected: selected,
          onPressed: model.selectionAvailable ? activate : null,
          // CSS border-box includes a 1px border outside its 12/14px padding.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          alignment: Alignment.topLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (model.selecting)
                Checkbox(
                  value: selected,
                  onChanged: model.selectionAvailable
                      ? (_) => activate()
                      : null,
                ),
              RecordIcon(r.type),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      r.name,
                      style: libraryText(
                        context,
                        14,
                        weight: FontWeight.w700,
                        color: selected ? c.accent : c.ink,
                      ),
                    ),
                    if (r.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(
                          r.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: libraryText(
                            context,
                            13,
                            height: 1.7,
                            color: c.muted,
                          ),
                        ),
                      ),
                    Padding(
                      // Adjacent CSS margins collapse: max(summary bottom5, meta top8).
                      padding: EdgeInsets.only(
                        top: r.description.isEmpty ? 8 : 3,
                      ),
                      child: Text(
                        r.type.name,
                        style: libraryText(context, 12, color: c.muted),
                      ),
                    ),
                    if (model.query.sort == WorkspaceSort.manual &&
                        model.catalog != null)
                      Tooltip(
                        message: directoryPath(model.catalog!, r.directoryId),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            directoryPath(model.catalog!, r.directoryId),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: libraryText(context, 12, color: c.muted),
                          ),
                        ),
                      ),
                    if (r.tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final tag in r.tags.take(2))
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: selected ? c.paper : c.rail,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  tag.name,
                                  style: libraryText(
                                    context,
                                    12,
                                    height: 1.5,
                                    color: c.muted,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return _dragRecord(r, content);
  }

  Widget _results(BuildContext context, LibraryMetrics metrics) {
    final c = UiPalette.of(context), results = model.results;
    Widget contents;
    if (model.loadState == WorkspaceLoad.error) {
      contents = SingleChildScrollView(
        primary: false,
        child: LibraryMessage(
          '暂时无法读取',
          description: model.failure?.message,
          action: DesktopButton(
            onPressed: widget.onRetry ?? () => model.load(model.query),
            child: const Text('重试'),
          ),
        ),
      );
    } else if (results == null) {
      contents = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (results.total == 0) {
      final empty = (model.catalog?.directoryCounts['all'] ?? 0) == 0;
      contents = SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.fromLTRB(12, 3, 10, 18),
        child: LibraryEmpty(
          empty ? '暂无资料' : '没有匹配的资料',
          key: const ValueKey('library-results-empty'),
          description: empty ? '添加一份资料开始整理。' : '换个关键词，或取消类型和标签。',
          action: DesktopButton(
            key: ValueKey(
              empty ? 'library-empty-create' : 'library-clear-filters',
            ),
            minimumSize: const Size(0, 38.4),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            onPressed: empty ? () => _edit(create: true) : model.clearFilters,
            child: Text(
              empty ? '添加资料' : '清除筛选',
              style: libraryText(
                context,
                14,
                color: c.muted,
                weight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    } else {
      final rows = <({Key key, Widget Function() build})>[];
      for (var i = 0; i < results.items.length; i++) {
        final r = results.items[i], group = _groupKey(r);
        if (group.isNotEmpty &&
            (i == 0 || _groupKey(results.items[i - 1]) != group)) {
          rows.add((
            key: ValueKey('library-result-group-$group'),
            build: () => Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 24, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _groupLabel(r),
                      key: ValueKey('library-group-label-$group'),
                      style: libraryText(context, 12, color: c.muted),
                    ),
                  ),
                  Text(
                    '${results.groupCounts[group] ?? 0}',
                    key: ValueKey('library-group-count-$group'),
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ],
              ),
            ),
          ));
        }
        rows.add((
          key: ValueKey('library-result-row-${r.ref.key}'),
          build: () => _record(context, r),
        ));
      }
      final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
      // Rows have no editor state. Dispose offscreen rows rather than retaining
      // stale layout/semantics when an identity is reordered into the viewport.
      contents = ListView.builder(
        addAutomaticKeepAlives: false,
        key: const ValueKey('library-results-scroll'),
        controller: _list,
        padding: const EdgeInsets.fromLTRB(18, 3, 4, 18),
        itemCount: rows.length,
        findChildIndexCallback: (key) => indices[key],
        itemBuilder: (context, index) =>
            KeyedSubtree(key: rows[index].key, child: rows[index].build()),
      );
    }
    return Container(
      key: const ValueKey('library-results-pane'),
      width: metrics.resultsWidth,
      decoration: BoxDecoration(
        color: c.canvas,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          _header(context),
          Expanded(
            child: KeyedSubtree(key: _recordViewport, child: contents),
          ),
          Container(
            key: const ValueKey('library-results-footer'),
            constraints: const BoxConstraints(minHeight: 45),
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_groupName(model.query.grouping)} · ${_sortName(model.query.sort)}',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ),
                if ((results?.total ?? 0) > model.query.limit) ...[
                  DesktopButton(
                    tooltip: '上一页',
                    kind: DesktopButtonKind.quiet,
                    fontSize: 12,
                    onPressed: model.query.offset == 0
                        ? null
                        : () => model.load(
                            model.query.copyWith(
                              offset: (model.query.offset - model.query.limit)
                                  .clamp(0, results!.total),
                            ),
                          ),
                    child: const Text('‹'),
                  ),
                  DesktopButton(
                    tooltip: '下一页',
                    kind: DesktopButtonKind.quiet,
                    fontSize: 12,
                    onPressed:
                        model.query.offset + model.query.limit >=
                            (results?.total ?? 0)
                        ? null
                        : () => model.load(
                            model.query.copyWith(
                              offset: model.query.offset + model.query.limit,
                            ),
                          ),
                    child: const Text('›'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, LibraryMetrics metrics) {
    final c = UiPalette.of(context), detail = model.detail;
    final name =
        model.catalog?.directories
            .where((d) => d.id == (detail?.record.directoryId ?? 'unfiled'))
            .firstOrNull
            ?.name ??
        '未分类';
    return Container(
      key: const ValueKey('library-detail-pane'),
      margin: metrics.detailMargin,
      decoration: BoxDecoration(
        color: c.paper,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            key: const ValueKey('library-detail-toolbar'),
            constraints: const BoxConstraints(minHeight: 49),
            padding: EdgeInsets.symmetric(horizontal: metrics.toolbarPadding),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              spacing: 10,
              children: [
                if (_reading)
                  DesktopButton(
                    onPressed: _toggleReading,
                    kind: DesktopButtonKind.quiet,
                    leading: const PrototypeIcon(
                      PrototypeIconGlyph.back,
                      size: 16,
                    ),
                    child: const Text('退出展开'),
                  ),
                if (widget.onWorkspaceBack != null)
                  DesktopButton(
                    key: const ValueKey('workspace-back'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: widget.workspaceNavigationEnabled
                        ? widget.onWorkspaceBack
                        : null,
                    child: Text(widget.workspaceBackLabel),
                  ),
                if (model.canGoBack)
                  DesktopButton(
                    key: const ValueKey('library-back'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: model.goBack,
                    tooltip: '返回原查询',
                    padding: const EdgeInsets.all(6),
                    child: const PrototypeIcon(
                      PrototypeIconGlyph.back,
                      size: 16,
                    ),
                  ),
                Expanded(
                  child: Text(
                    detail == null
                        ? _directoryName
                        : '$name / ${detail.record.type.name}',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                ),
                DesktopButton(
                  key: const ValueKey('library-detail-create'),
                  kind: DesktopButtonKind.quiet,
                  fontSize: 13,
                  minimumSize: const Size(0, 36.8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 8,
                  ),
                  onPressed:
                      model.catalog == null ||
                          model.loadState == WorkspaceLoad.loading
                      ? null
                      : () => _edit(create: true),
                  child: Text(
                    '添加资料',
                    style: libraryText(
                      context,
                      13,
                      color: c.muted,
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (model.navigationNotice != null || model.scopeNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                model.navigationNotice ?? model.scopeNotice!,
                style: libraryText(context, 12, color: c.muted),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('library-detail-scroll'),
              controller: _detailScroll,
              padding: metrics.detailPadding,
              child: model.loadState == WorkspaceLoad.error
                  ? LibraryMessage('资料暂不可用')
                  : model.loadState == WorkspaceLoad.loading && detail == null
                  ? const LibraryMessage('正在读取资料…')
                  : detail == null
                  ? model.detailFailure == null
                        ? const LibraryEmpty(
                            '选择一份资料',
                            key: ValueKey('library-detail-empty'),
                            description: '查看内容、文件与关联关系。',
                          )
                        : LibraryMessage(
                            model.detailFailure?.code == 'not_found'
                                ? '资料已不存在'
                                : '选择一份资料',
                            description:
                                model.detailFailure?.message ?? '查看内容、文件与关联关系。',
                          )
                  : DesktopEntrance(
                      key: ValueKey(detail.record.ref),
                      child: LibraryDetail(
                        key: ValueKey(detail.record.ref),
                        detail: detail,
                        source: model.source,
                        metrics: metrics,
                        revision: model.revision,
                        filePicker: widget.filePicker,
                        credentialPicker: widget.credentialPicker,
                        onModalChanged: widget.onModalChanged,
                        onOpen: model.openRelated,
                        onEdit: model.loadState == WorkspaceLoad.loading
                            ? null
                            : () => _edit(),
                        onHistory: model.loadState != WorkspaceLoad.loading
                            ? _history
                            : null,
                        onMove: _canMove && model.selectionAvailable
                            ? () => _manage(
                                WorkspaceLibrarySelection(
                                  records: [detail.record.ref],
                                ),
                                moving: true,
                              )
                            : null,
                        onOrder:
                            _canOrder && model.selectionAvailable && !_placing
                            ? () => _place(
                                WorkspaceLibrarySelection(
                                  records: [detail.record.ref],
                                ),
                              )
                            : null,
                        onRecycle: model.loadState != WorkspaceLoad.loading
                            ? _recycleCurrent
                            : null,
                        onAdopt:
                            model.loadState != WorkspaceLoad.loading &&
                                detail.record.ref.kind ==
                                    WorkspaceRecordKind.information
                            ? _adopt
                            : null,
                        onApproval: (id) =>
                            widget.onNavigate(WorkspacePage.approvals, id),
                        onTag: (id) =>
                            model.apply(model.query.copyWith(tagId: id)),
                        onSettings: () => widget.onNavigate(
                          WorkspacePage.settings,
                          'plugin:builtin.server/host:${detail.record.ref.id}',
                        ),
                        onExpand: _toggleReading,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (_drag != null)
        const SingleActivator(LogicalKeyboardKey.escape): _cancelDrag
      else if (_reading)
        const SingleActivator(LogicalKeyboardKey.escape): _toggleReading,
      SingleActivator(
        LogicalKeyboardKey.keyK,
        meta: Theme.of(context).platform == TargetPlatform.macOS,
        control: Theme.of(context).platform != TargetPlatform.macOS,
      ): model.focusSearch,
    },
    child: Focus(
      focusNode: _workspaceFocus,
      autofocus: true,
      child: ScrollConfiguration(
        behavior: DesktopScrollBehavior(
          scrollbarGutter: DesktopScrollbarScope.gutterOf(context, 11),
        ),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final metrics = LibraryMetrics(bounds.maxWidth);
            if (_recyclePage) {
              return LibraryRecyclePage(
                source: model.source,
                onModalChanged: widget.onModalChanged,
                onBack: () => setState(() => _recyclePage = false),
                onOpen: (ref) {
                  setState(() => _recyclePage = false);
                  model.openRelated(ref);
                },
              );
            }
            if (_reading) {
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: bounds.maxWidth.clamp(0, 1100).toDouble(),
                  height: bounds.maxHeight,
                  child: _detail(context, metrics),
                ),
              );
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  key: const ValueKey('library-workspace'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _side(context, metrics),
                    _results(context, metrics),
                    Expanded(child: _detail(context, metrics)),
                  ],
                ),
                if (_dropHint != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: IgnorePointer(
                      child: Material(
                        elevation: 6,
                        color: UiPalette.of(context).paper,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _dropHint!.label,
                              key: const ValueKey('library-drop-hint'),
                              style: TextStyle(
                                color: _dropHint!.allowed
                                    ? UiPalette.of(context).accent
                                    : UiPalette.of(context).danger,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
