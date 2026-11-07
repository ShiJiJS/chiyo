import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../ui_palette.dart';
import 'directory_tree.dart';
import 'workspace_source.dart';

class LibraryDragData {
  LibraryDragData(
    this.origin,
    this.selection,
    WorkspaceCatalog catalog,
    Iterable<WorkspaceRecordSummary> visible,
  ) {
    final children = <String?, List<String>>{};
    for (final d in catalog.directories) {
      children.putIfAbsent(d.parentId, () => []).add(d.id);
    }
    final pending = selection.directoryIds.toList();
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!includedDirectories.add(id)) continue;
      pending.addAll(children[id] ?? const []);
    }
    final records = {for (final r in visible) r.ref: r};
    directoryOnly =
        selection.directoryIds.isNotEmpty &&
        selection.records.every(
          (r) =>
              records[r] != null &&
              includedDirectories.contains(records[r]!.directoryId),
        );
  }
  final WorkspaceSource origin;
  final WorkspaceLibrarySelection selection;
  final includedDirectories = <String>{};
  late final bool directoryOnly;
  bool get recordOnly =>
      selection.directoryIds.isEmpty && selection.records.isNotEmpty;
  int get count => selection.directoryIds.length + selection.records.length;
  int? pointer;
  bool cancelled = false;
}

enum LibraryDropZone { into, before, after }

class LibraryDropHint {
  const LibraryDropHint(this.label, this.zone, [this.placement]);
  final String label;
  final LibraryDropZone zone;
  final WorkspaceLibraryPlacement? placement;
  bool get allowed => placement != null;
  bool sameAs(LibraryDropHint? other) =>
      other?.label == label && other?.zone == zone && other?.allowed == allowed;
}

String? _directoryCollision(
  LibraryDragData data,
  WorkspaceCatalog catalog,
  String? parent,
) {
  final roots = catalog.directories
      .where(
        (d) =>
            data.includedDirectories.contains(d.id) &&
            !data.includedDirectories.contains(d.parentId),
      )
      .toList();
  final ids = roots.map((d) => d.id).toSet();
  final names = {
    for (final d in catalog.directories)
      if (d.parentId == parent && !ids.contains(d.id))
        d.name.trim().toLowerCase(),
  };
  for (final d in roots) {
    if (!names.add(d.name.trim().toLowerCase())) return '目标已有同名目录，请先更名或选择其他位置。';
  }
  return null;
}

LibraryDropHint libraryDirectoryDrop(
  LibraryDragData data,
  WorkspaceDirectory d,
  WorkspaceCatalog catalog,
  double fraction, {
  required bool canOrder,
}) {
  if (data.cancelled) {
    return const LibraryDropHint('已取消拖动', LibraryDropZone.into);
  }
  if (d.id == 'all') {
    return const LibraryDropHint('全部资料不是存放目录，请选择具体目录。', LibraryDropZone.into);
  }
  if (d.id == 'unfiled') {
    return data.recordOnly
        ? const LibraryDropHint(
            '放入“未分类”',
            LibraryDropZone.into,
            WorkspaceLibraryPlacement(null),
          )
        : const LibraryDropHint(
            '目录不能放进“未分类”，请选择具体目录或上级位置。',
            LibraryDropZone.into,
          );
  }
  if (data.includedDirectories.contains(d.id)) {
    return const LibraryDropHint(
      '不能移入自己或自己的子目录，也不能以选中的目录作为排序目标。',
      LibraryDropZone.into,
    );
  }
  final zone = canOrder && data.directoryOnly
      ? (fraction < .25
            ? LibraryDropZone.before
            : fraction > .75
            ? LibraryDropZone.after
            : LibraryDropZone.into)
      : LibraryDropZone.into;
  final parent = zone == LibraryDropZone.into ? d.id : d.parentId;
  final collision = _directoryCollision(data, catalog, parent);
  if (collision != null) return LibraryDropHint(collision, zone);
  final path = directoryPath(catalog, d.id);
  return zone == LibraryDropZone.into
      ? LibraryDropHint('放入“$path”', zone, WorkspaceLibraryPlacement(d.id))
      : LibraryDropHint(
          '排在“$path”${zone == LibraryDropZone.after ? '之后' : '之前'}',
          zone,
          WorkspaceLibraryPlacement(
            d.parentId,
            position: WorkspaceLibraryPosition.directory(
              d.id,
              after: zone == LibraryDropZone.after,
            ),
          ),
        );
}

LibraryDropHint libraryRecordDrop(
  LibraryDragData data,
  WorkspaceRecordSummary r,
  WorkspaceCatalog catalog,
  double fraction, {
  required bool manual,
}) {
  final zone = fraction < .5 ? LibraryDropZone.before : LibraryDropZone.after;
  if (data.cancelled) return LibraryDropHint('已取消拖动', zone);
  if (!manual) return LibraryDropHint('请先切换“手动顺序”，再调整资料前后位置；也可以直接拖进目录。', zone);
  if (!data.recordOnly) {
    return LibraryDropHint('目录请拖进其他目录；目录和单独资料请分别调整顺序。', zone);
  }
  if (data.selection.records.contains(r.ref)) {
    return LibraryDropHint('不能以选中的资料作为排序目标。', zone);
  }
  final path = directoryPath(catalog, r.directoryId);
  return LibraryDropHint(
    '排在“$path / ${r.name}”${zone == LibraryDropZone.after ? '之后' : '之前'}',
    zone,
    WorkspaceLibraryPlacement(
      r.directoryId,
      position: WorkspaceLibraryPosition.record(
        r.ref,
        after: zone == LibraryDropZone.after,
      ),
    ),
  );
}

class LibraryDragHandle extends StatefulWidget {
  const LibraryDragHandle({
    super.key,
    required this.data,
    required this.enabled,
    required this.onStart,
    required this.child,
  });
  final LibraryDragData data;
  final bool enabled;
  final VoidCallback onStart;
  final Widget child;
  @override
  State<LibraryDragHandle> createState() => _LibraryDragHandleState();
}

class _LibraryDragHandleState extends State<LibraryDragHandle> {
  int? _pointer;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Listener(
      onPointerDown: (e) => _pointer = e.pointer,
      child: Draggable<LibraryDragData>(
        data: widget.data,
        maxSimultaneousDrags: widget.enabled ? 1 : 0,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        allowedButtonsFilter: (buttons) =>
            buttons == kPrimaryMouseButton &&
            !HardwareKeyboard.instance.isControlPressed,
        onDragStarted: () {
          widget.data.pointer = _pointer;
          widget.onStart();
        },
        feedback: Transform.translate(
          offset: const Offset(14, 14),
          child: Material(
            color: c.paper,
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '移动 ${widget.data.count} 项',
                style: TextStyle(fontSize: 14, color: c.ink),
              ),
            ),
          ),
        ),
        childWhenDragging: ExcludeSemantics(
          child: Opacity(opacity: .45, child: widget.child),
        ),
        child: widget.child,
      ),
    );
  }
}

/// Tracks the visible target at the actual pointer position. Flutter's drag
/// avatar does not re-hit-test after a scroll with a stationary pointer, so a
/// saved DragTarget candidate alone cannot decide which row receives the drop.
class LibraryDragRegistry {
  LibraryDragRegistry({required this.onHover, required this.onOutside});
  final void Function(Offset, LibraryDropHint, String?) onHover;
  final VoidCallback onOutside;
  final _regions = <_LibraryDropRegionState>{};
  _LibraryDropRegionState? _active;
  _LibraryDropRegionState? _at(LibraryDragData data, Offset point) {
    for (final region in _regions) {
      if (region.contains(data, point)) return region;
    }
    return null;
  }

  void update(LibraryDragData data, Offset point) {
    final target = _at(data, point);
    if (!identical(target, _active)) _active?.show(null);
    _active = target;
    if (target == null) {
      onOutside();
      return;
    }
    final hint = target.resolve(data, point);
    target.show(hint);
    onHover(point, hint, target.widget.directoryId);
  }

  WorkspaceLibraryPlacement? placementAt(LibraryDragData data, Offset point) =>
      data.cancelled ? null : _at(data, point)?.resolve(data, point).placement;
  void clear({bool paint = true}) {
    if (paint) _active?.show(null);
    _active = null;
  }
}

class LibraryDropRegion extends StatefulWidget {
  const LibraryDropRegion({
    super.key,
    required this.registry,
    required this.origin,
    required this.enabled,
    required this.viewport,
    required this.resolve,
    this.directoryId,
    required this.child,
  });
  final LibraryDragRegistry registry;
  final WorkspaceSource origin;
  final bool enabled;
  final Rect? Function() viewport;
  final String? directoryId;
  final LibraryDropHint Function(LibraryDragData, double) resolve;
  final Widget child;
  @override
  State<LibraryDropRegion> createState() => _LibraryDropRegionState();
}

class _LibraryDropRegionState extends State<LibraryDropRegion> {
  LibraryDropHint? _hint;
  @override
  void initState() {
    super.initState();
    widget.registry._regions.add(this);
  }

  @override
  void didUpdateWidget(LibraryDropRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.registry, oldWidget.registry)) {
      oldWidget.registry._regions.remove(this);
      widget.registry._regions.add(this);
    }
  }

  @override
  void dispose() {
    widget.registry._regions.remove(this);
    if (identical(widget.registry._active, this)) {
      widget.registry._active = null;
    }
    super.dispose();
  }

  bool contains(LibraryDragData data, Offset point) {
    if (!mounted ||
        !widget.enabled ||
        data.cancelled ||
        !identical(data.origin, widget.origin)) {
      return false;
    }
    final view = widget.viewport();
    if (view == null || !view.contains(point)) return false;
    final box = context.findRenderObject() as RenderBox?;
    // A focused or otherwise retained sliver child can have stale paint
    // coordinates outside the viewport. It must never shadow the visible row.
    RenderObject? ancestor = box;
    while (ancestor != null) {
      final data = ancestor.parentData;
      if (data is SliverMultiBoxAdaptorParentData && data.keptAlive) {
        return false;
      }
      ancestor = ancestor.parent;
    }
    return box != null &&
        box.attached &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(point));
  }

  LibraryDropHint resolve(LibraryDragData data, Offset point) {
    final box = context.findRenderObject() as RenderBox;
    return widget.resolve(
      data,
      (box.globalToLocal(point).dy / box.size.height).clamp(0.0, 1.0),
    );
  }

  void show(LibraryDropHint? hint) {
    if (mounted && (hint == null ? _hint != null : !hint.sameAs(_hint))) {
      setState(() => _hint = hint);
    }
  }

  @override
  Widget build(BuildContext context) => DragTarget<LibraryDragData>(
    onWillAcceptWithDetails: (d) =>
        widget.enabled &&
        identical(d.data.origin, widget.origin) &&
        !d.data.cancelled,
    onMove: (d) => widget.registry.update(d.data, d.offset),
    // The workspace finishes once, after resolving the current visible row. Never
    // write from this callback: its candidate may precede an auto-scroll.
    onAcceptWithDetails: (_) {},
    builder: (context, candidates, rejected) {
      final hint = _hint, c = UiPalette.of(context);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (hint != null)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: hint.zone == LibraryDropZone.into || !hint.allowed
                        ? Border.all(
                            color: hint.allowed ? c.accent : c.danger,
                            width: 2,
                          )
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          if (hint?.allowed == true && hint!.zone != LibraryDropZone.into)
            Positioned(
              left: 0,
              right: 0,
              top: hint.zone == LibraryDropZone.before ? 0 : null,
              bottom: hint.zone == LibraryDropZone.after ? 0 : null,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('library-drop-insertion'),
                  height: 3,
                  color: c.accent,
                ),
              ),
            ),
        ],
      );
    },
  );
}

class LibraryDragAutoScroller {
  LibraryDragAutoScroller(this.onScrolled);
  final VoidCallback onScrolled;
  Timer? _timer;
  ScrollController? _controller;
  double _speed = 0;
  void update(ScrollController controller, Rect viewport, Offset pointer) {
    final top = viewport.top + 44, bottom = viewport.bottom - 44;
    final speed = pointer.dy < top
        ? -((top - pointer.dy) / 44 * 16).clamp(0.0, 20.0)
        : pointer.dy > bottom
        ? ((pointer.dy - bottom) / 44 * 16).clamp(0.0, 20.0)
        : 0.0;
    if (!controller.hasClients || speed == 0) {
      stop();
      return;
    }
    _controller = controller;
    _speed = speed;
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final c = _controller;
      if (c == null || !c.hasClients) {
        stop();
        return;
      }
      final next = (c.offset + _speed).clamp(
        c.position.minScrollExtent,
        c.position.maxScrollExtent,
      );
      if (next != c.offset) {
        c.jumpTo(next);
        onScrolled();
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _controller = null;
    _speed = 0;
  }
}
