import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Layout changes can replace an outer ScrollPosition without rebuilding a
/// retained field. Scroll/metrics notifications reach this window-level host even
/// when the field itself is below that scrollable in the widget tree.
class MacTextFieldAccessibilityHost extends StatelessWidget {
  const MacTextFieldAccessibilityHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return child;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _Labels.changed();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _Labels.changed();
          return false;
        },
        child: child,
      ),
    );
  }
}

/// Supplies purpose/geometry and ordinary text to the owning AppKit AX shim.
/// Obscured text is excluded. Mirrors the already-selected keyboard field and
/// its selection; the adapter never chooses a different Flutter input target.
class MacTextFieldAccessibility extends StatefulWidget {
  const MacTextFieldAccessibility({
    super.key,
    required this.label,
    required this.child,
  });
  final String label;
  final Widget child;
  @override
  State<MacTextFieldAccessibility> createState() =>
      _MacTextFieldAccessibilityState();
}

class _MacTextFieldAccessibilityState extends State<MacTextFieldAccessibility>
    with WidgetsBindingObserver {
  final _box = GlobalKey();
  final _positions = <ScrollPosition>{};
  final _scrollables = <ScrollableState>[];
  TextEditingController? _controller;
  FocusNode? _focus;
  bool _visible = true;
  final _native = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    if (_native) {
      WidgetsBinding.instance.addObserver(this);
      _Labels.fields.add(this);
      _Labels.changed();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_native) return;
    // IndexedStack retains all pages and their layout. Subscribe to all
    // ancestor visibility scopes so a tab switch refreshes even const fields.
    _visible = Visibility.of(context);
    // Retain the nearest inherited dependency as well as all outer positions.
    Scrollable.maybeOf(context);
    _observeScrollables();
    _Labels.changed();
  }

  @override
  void didUpdateWidget(MacTextFieldAccessibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_native) _Labels.changed();
  }

  @override
  void didChangeMetrics() => _Labels.changed();

  void _observeScrollables() {
    _scrollables.clear();
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        _scrollables.add(element.state as ScrollableState);
      }
      return true;
    });
    final positions = {
      for (final scrollable in _scrollables) scrollable.position,
    };
    for (final position in _positions.difference(positions)) {
      position.removeListener(_Labels.changed);
    }
    for (final position in positions.difference(_positions)) {
      position.addListener(_Labels.changed);
    }
    _positions
      ..clear()
      ..addAll(positions);
  }

  Map<String, Object>? geometry() {
    final box = _box.currentContext?.findRenderObject();
    if (!mounted ||
        !_visible ||
        box is! RenderBox ||
        !box.attached ||
        !box.hasSize) {
      return null;
    }
    _observeScrollables();
    var rect = box.localToGlobal(Offset.zero) & box.size;
    final view = View.of(context);
    rect = rect.intersect(
      Offset.zero & (view.physicalSize / view.devicePixelRatio),
    );
    for (final scrollable in _scrollables) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
        rect = rect.intersect(
          viewport.localToGlobal(Offset.zero) & viewport.size,
        );
      }
    }
    if (!rect.isFinite || rect.isEmpty) return null;
    // TextFormField may own its controller internally. Follow the actual
    // EditableText instead of requiring every form to expose that controller.
    final editors = <EditableText>[];
    void visit(Element element) {
      if (element.widget case final EditableText editor) {
        editors.add(editor);
      } else {
        element.visitChildren(visit);
      }
    }

    (_box.currentContext! as Element).visitChildren(visit);
    final editor = editors.length == 1 && !editors.single.obscureText
        ? editors.single
        : null;
    if (!identical(_controller, editor?.controller)) {
      _controller?.removeListener(_Labels.changed);
      _controller = editor?.controller;
      _controller?.addListener(_Labels.changed);
    }
    if (!identical(_focus, editor?.focusNode)) {
      _focus?.removeListener(_Labels.changed);
      _focus = editor?.focusNode;
      _focus?.addListener(_Labels.changed);
    }
    return {
      'label': widget.label,
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
      if (editor != null) ...{
        'text': editor.controller.text,
        'keyboardFocused': editor.focusNode.hasFocus,
        'selection': [
          editor.controller.selection.baseOffset,
          editor.controller.selection.extentOffset,
        ],
        'composing': [
          editor.controller.value.composing.start,
          editor.controller.value.composing.end,
        ],
      },
    };
  }

  @override
  void dispose() {
    if (_native) {
      WidgetsBinding.instance.removeObserver(this);
      for (final position in _positions) {
        position.removeListener(_Labels.changed);
      }
      _controller?.removeListener(_Labels.changed);
      _focus?.removeListener(_Labels.changed);
      _Labels.fields.remove(this);
      _Labels.changed();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    key: _box,
    container: true,
    label: widget.label,
    child: widget.child,
  );
}

abstract final class _Labels {
  static const channel = MethodChannel(
    'agent_info_manage/text_field_accessibility',
  );
  static final fields = <_MacTextFieldAccessibilityState>{};
  static bool scheduled = false;

  static void changed() {
    if (scheduled) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      final labels = [for (final field in fields) ?field.geometry()];
      unawaited(send(labels));
    });
    // A callback added after a scroll frame must not wait for another edit.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static Future<void> send(List<Map<String, Object>> labels) async {
    try {
      await channel.invokeMethod<void>('update', labels);
    } on MissingPluginException {
      // Framework semantics remain available in tests and non-native hosts.
    } on PlatformException {
      // A rejected native update must not interfere with editing or focus.
    }
  }
}
