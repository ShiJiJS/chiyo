import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Supplies purpose/geometry and ordinary text to the owning AppKit AX shim.
/// Obscured text is excluded. No selection or focus commands cross this seam.
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
  ScrollableState? _scrollable;
  ScrollPosition? _position;
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
    final next = Scrollable.maybeOf(context);
    final position = next?.position;
    // ScrollableState can survive a physics/theme change while its concrete
    // ScrollPosition is replaced. Follow the actual listener owner.
    if (!identical(position, _position)) {
      _position?.removeListener(_Labels.changed);
      _position = position;
      position?.addListener(_Labels.changed);
    }
    _scrollable = next;
    _Labels.changed();
  }

  @override
  void didUpdateWidget(MacTextFieldAccessibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_native) _Labels.changed();
  }

  @override
  void didChangeMetrics() => _Labels.changed();

  Map<String, Object>? geometry() {
    final box = _box.currentContext?.findRenderObject();
    if (!mounted ||
        !_visible ||
        box is! RenderBox ||
        !box.attached ||
        !box.hasSize) {
      return null;
    }
    var rect = box.localToGlobal(Offset.zero) & box.size;
    final view = View.of(context);
    rect = rect.intersect(
      Offset.zero & (view.physicalSize / view.devicePixelRatio),
    );
    final viewport = _scrollable?.context.findRenderObject();
    if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
      rect = rect.intersect(
        viewport.localToGlobal(Offset.zero) & viewport.size,
      );
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
      if (editor != null) ...{'text': editor.controller.text, 'keyboardFocused': editor.focusNode.hasFocus, 'selection': [editor.controller.selection.baseOffset, editor.controller.selection.extentOffset], 'composing': [editor.controller.value.composing.start, editor.controller.value.composing.end]},
    };
  }

  @override
  void dispose() {
    if (_native) {
      WidgetsBinding.instance.removeObserver(this);
      _position?.removeListener(_Labels.changed);
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
