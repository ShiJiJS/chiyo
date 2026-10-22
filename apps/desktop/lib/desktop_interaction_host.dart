import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds keyboard access to both explicit and IconButton-provided tooltips,
/// without adding another tab stop inside the button.
class DesktopInteractionHost extends StatefulWidget {
  const DesktopInteractionHost({super.key, required this.child});
  final Widget child;
  @override
  State<DesktopInteractionHost> createState() => _DesktopInteractionHostState();
}

class _DesktopInteractionHostState extends State<DesktopInteractionHost> {
  bool _keyboard = false;
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    if (!_keyboard) return;
    final node = FocusManager.instance.primaryFocus;
    Tooltip.dismissAllToolTips();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          node != FocusManager.instance.primaryFocus ||
          !(node?.context?.mounted ?? false)) {
        return;
      }
      TooltipState? target = node!.context!
          .findAncestorStateOfType<TooltipState>();
      void visit(Element element) {
        if (target != null) return;
        if (element is StatefulElement && element.state is TooltipState) {
          target = element.state as TooltipState;
          return;
        }
        element.visitChildren(visit);
      }

      if (target == null) node.context!.visitChildElements(visit);
      target?.ensureTooltipVisible();
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      _keyboard = false;
      Tooltip.dismissAllToolTips();
    },
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape &&
            Tooltip.dismissAllToolTips()) {
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.tab ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _keyboard = true;
        }
        if (event.logicalKey == LogicalKeyboardKey.f1) {
          _keyboard = true;
          _focusChanged();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    ),
  );
}
