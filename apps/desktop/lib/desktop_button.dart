import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'desktop_motion.dart';
import 'ui_palette.dart';

enum DesktopButtonKind { quiet, menu, outline, primary, danger }

/// The shared desktop action. Its pressed translation does not move adjacent
/// controls, and selection/hover resolve to a single background.
class DesktopButton extends StatefulWidget {
  const DesktopButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.kind = DesktopButtonKind.outline,
    this.selected = false,
    this.busy = false,
    this.leading,
    this.leadingGap = 7,
    this.focusNode,
    this.tooltip,
    this.fontSize = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.minimumSize = const Size(0, 36),
    this.alignment = Alignment.center,
    this.radius = 7,
    this.selectedBorder = false,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final DesktopButtonKind kind;
  final bool selected, busy;
  final Widget? leading;
  final double leadingGap;
  final FocusNode? focusNode;
  final String? tooltip;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final Size minimumSize;
  final AlignmentGeometry alignment;
  final double radius;
  final bool selectedBorder;
  @override
  State<DesktopButton> createState() => _DesktopButtonState();
}

class _DesktopButtonState extends State<DesktopButton> {
  final _states = WidgetStatesController();
  @override
  void initState() {
    super.initState();
    _states.addListener(_changed);
  }

  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final enabled = widget.onPressed != null && !widget.busy;
    final primary = widget.kind == DesktopButtonKind.primary;
    final menu = widget.kind == DesktopButtonKind.menu;
    final quiet = widget.kind == DesktopButtonKind.quiet || menu;
    final menuFocus =
        menu &&
        _states.value.contains(WidgetState.focused) &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final menuActive =
        menu && (_states.value.contains(WidgetState.hovered) || menuFocus);
    final ink = primary
        ? c.onAccent
        : widget.selected || menuActive
        ? c.accent
        : widget.kind == DesktopButtonKind.danger
        ? c.danger
        : c.ink;
    Color background(Set<WidgetState> states) {
      if (primary) {
        return states.contains(WidgetState.hovered)
            ? Color.lerp(c.accent, Colors.black, .06)!
            : c.accent;
      }
      if (widget.selected) return c.selected;
      if (states.contains(WidgetState.hovered) || menuFocus) {
        return menu ? c.selected : c.nav;
      }
      // Match CSS premultiplied-alpha interpolation when a quiet button fades
      // from transparent to its hover surface, without an intermediate dark flash.
      return quiet ? c.nav.withValues(alpha: 0) : c.paper;
    }

    Widget action = Opacity(
      opacity: enabled || widget.busy ? 1 : .5,
      child: AnimatedContainer(
        duration: DesktopMotion.feedbackOf(context),
        curve: Curves.ease,
        decoration: BoxDecoration(
          color: background(_states.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        transform: Matrix4.translationValues(
          0,
          enabled && _states.value.contains(WidgetState.pressed) ? 1 : 0,
          0,
        ),
        child: TextButton(
          statesController: _states,
          focusNode: widget.focusNode,
          onPressed: enabled ? widget.onPressed : null,
          style: ButtonStyle(
            animationDuration: DesktopMotion.feedbackOf(context),
            alignment: widget.alignment,
            foregroundColor: WidgetStatePropertyAll(ink),
            // Material does not tween this color on the pinned Flutter SDK.
            // Keep the CSS ease transition in the shared animated surface.
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
            padding: WidgetStatePropertyAll(widget.padding),
            minimumSize: WidgetStatePropertyAll(widget.minimumSize),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStatePropertyAll(
              Theme.of(context).textTheme.bodyMedium!.copyWith(
                fontSize: widget.fontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
            shape: WidgetStateProperty.resolveWith((states) {
              final focused =
                  states.contains(WidgetState.focused) &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional;
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(widget.radius),
                side: focused
                    ? BorderSide(color: c.accent, width: 2)
                    : BorderSide(
                        color: primary
                            ? c.accent
                            : quiet &&
                                  !(widget.selected && widget.selectedBorder)
                            ? Colors.transparent
                            : c.line,
                      ),
              );
            }),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.busy) ...[
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: ink,
                  ),
                ),
                SizedBox(width: widget.leadingGap),
              ] else if (widget.leading != null) ...[
                IconTheme(
                  data: IconThemeData(size: 19, color: ink),
                  child: widget.leading!,
                ),
                SizedBox(width: widget.leadingGap),
              ],
              Flexible(child: widget.child),
            ],
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      action = Tooltip(message: widget.tooltip!, child: action);
    }
    return action;
  }
}
