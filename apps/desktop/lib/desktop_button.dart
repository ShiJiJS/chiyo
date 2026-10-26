import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'desktop_motion.dart';
import 'ui_palette.dart';

enum DesktopButtonKind { quiet, outline, primary, danger }

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
  @override
  State<DesktopButton> createState() => _DesktopButtonState();
}

class _DesktopButtonState extends State<DesktopButton> {
  final _states = WidgetStatesController();
  bool _pressed = false;
  @override
  void initState() {
    super.initState();
    _states.addListener(_changed);
  }

  void _changed() {
    final pressed = _states.value.contains(WidgetState.pressed);
    if (_pressed == pressed) return;
    _pressed = pressed;
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
    final quiet = widget.kind == DesktopButtonKind.quiet;
    final ink = primary
        ? c.onAccent
        : widget.selected
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
      if (states.contains(WidgetState.hovered)) return c.nav;
      return quiet ? Colors.transparent : c.paper;
    }

    Widget action = Opacity(
      opacity: enabled || widget.busy ? 1 : .5,
      child: AnimatedContainer(
        duration: DesktopMotion.feedbackOf(context),
        curve: Curves.ease,
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
            backgroundColor: WidgetStateProperty.resolveWith(background),
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
                borderRadius: BorderRadius.circular(7),
                side: focused
                    ? BorderSide(color: c.accent, width: 2)
                    : BorderSide(
                        color: primary
                            ? c.accent
                            : quiet
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
