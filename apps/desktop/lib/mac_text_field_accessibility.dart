import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the framework label and supplies purpose/geometry to AppKit's
/// editable-field shim. No text, selection or focus commands cross this seam.
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
    final next = Scrollable.maybeOf(context);
    if (!identical(next, _scrollable)) {
      _scrollable?.position.removeListener(_Labels.changed);
      _scrollable = next;
      next?.position.addListener(_Labels.changed);
    }
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
    if (!mounted || box is! RenderBox || !box.attached || !box.hasSize) {
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
    return {
      'label': widget.label,
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
  }

  @override
  void dispose() {
    if (_native) {
      WidgetsBinding.instance.removeObserver(this);
      _scrollable?.position.removeListener(_Labels.changed);
      _Labels.fields.remove(this);
      _Labels.changed();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Semantics(key: _box, label: widget.label, child: widget.child);
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
