import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui_palette.dart';

/// Pointer and keyboard context menus share the same action callback. Control
/// clicking must not also activate the underlying row when the pointer lifts.
class LibraryContextRegion extends StatefulWidget {
  const LibraryContextRegion({
    super.key,
    required this.onActivate,
    required this.onContext,
    required this.builder,
    this.enabled = true,
  });
  final VoidCallback onActivate;
  final Future<void> Function(Offset) onContext;
  final Widget Function(VoidCallback) builder;
  final bool enabled;
  @override
  State<LibraryContextRegion> createState() => _LibraryContextRegionState();
}

class _LibraryContextRegionState extends State<LibraryContextRegion> {
  bool _suppress = false;
  Future<void> _openContext(Offset position) async {
    try {
      await widget.onContext(position);
    } finally {
      _suppress = false;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      if (!widget.enabled || event is! KeyDownEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey != LogicalKeyboardKey.contextMenu &&
          !(event.logicalKey == LogicalKeyboardKey.f10 &&
              HardwareKeyboard.instance.isShiftPressed)) {
        return KeyEventResult.ignored;
      }
      final box = context.findRenderObject() as RenderBox?;
      if (box != null) {
        unawaited(
          widget.onContext(box.localToGlobal(box.size.center(Offset.zero))),
        );
      }
      return KeyEventResult.handled;
    },
    child: Listener(
      onPointerDown: (event) {
        _suppress =
            widget.enabled &&
            (event.buttons & kSecondaryMouseButton != 0 ||
                event.buttons & kPrimaryMouseButton != 0 &&
                    HardwareKeyboard.instance.isControlPressed);
        if (_suppress) unawaited(_openContext(event.position));
      },
      child: widget.builder(() {
        if (!_suppress) widget.onActivate();
      }),
    ),
  );
}

Future<T?> showLibraryContextMenu<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
) {
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final local = overlay.globalToLocal(position);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: items,
    color: UiPalette.of(context).paper,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.black26,
    elevation: 8,
    menuPadding: const EdgeInsets.symmetric(vertical: 6),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    constraints: const BoxConstraints(minWidth: 190, maxWidth: 290),
  );
}
