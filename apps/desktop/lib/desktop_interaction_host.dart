import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shares keyboard/pointer modality for focus cues and adds keyboard access to
/// tooltips, without adding another tab stop inside the button.
class DesktopInteractionHost extends StatefulWidget {
  const DesktopInteractionHost({super.key, required this.child});
  final Widget child;

  /// Standalone controls can fall back to Flutter's highlight policy.
  static bool? keyboardInputOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DesktopInputMode>()?.keyboard;
  @override
  State<DesktopInteractionHost> createState() => _DesktopInteractionHostState();
}

class _DesktopInteractionHostState extends State<DesktopInteractionHost> {
  bool _keyboard = false;
  bool _keyboardInput = false;
  static final _modifierKeys = {
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_observeKeyInput);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_observeKeyInput);
    super.dispose();
  }

  void _inputMode(bool keyboard) {
    if (mounted && _keyboardInput != keyboard) {
      setState(() => _keyboardInput = keyboard);
    }
  }

  KeyEventResult _observeKeyInput(KeyEvent event) {
    // Observe before a child consumes Enter/Space. Never handle the key:
    // activation and traversal retain their existing owners.
    if (event is KeyDownEvent && !_modifierKeys.contains(event.logicalKey)) {
      _inputMode(true);
    }
    return KeyEventResult.ignored;
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
      _inputMode(false);
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
      child: _DesktopInputMode(keyboard: _keyboardInput, child: widget.child),
    ),
  );
}

class _DesktopInputMode extends InheritedWidget {
  const _DesktopInputMode({required this.keyboard, required super.child});
  final bool keyboard;

  @override
  bool updateShouldNotify(_DesktopInputMode oldWidget) =>
      keyboard != oldWidget.keyboard;
}
