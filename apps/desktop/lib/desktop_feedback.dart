import 'dart:async';
import 'package:flutter/material.dart';
import 'desktop_motion.dart';
import 'ui_palette.dart';

/// One transient status per window; replacing it cancels its old lifetime.
/// Call only after the data source has returned the operation's result.
class DesktopFeedback extends StatefulWidget {
  const DesktopFeedback({super.key, required this.child});
  final Widget child;
  static void show(BuildContext context, String message) =>
      context.findAncestorStateOfType<_DesktopFeedbackState>()?.show(message);
  static void dismiss(BuildContext context) =>
      context.findAncestorStateOfType<_DesktopFeedbackState>()?.dismiss();
  @override
  State<DesktopFeedback> createState() => _DesktopFeedbackState();
}

class _DesktopFeedbackState extends State<DesktopFeedback> {
  Timer? _timer;
  String? _message;
  int _revision = 0;
  void dismiss() {
    _timer?.cancel();
    if (_message != null) setState(() => _message = null);
  }

  void show(String message) {
    _timer?.cancel();
    setState(() {
      _message = message;
      _revision++;
    });
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _message = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Stack(
      children: [
        widget.child,
        if (_message != null)
          Positioned(
            bottom: 25,
            left: 15,
            right: 15,
            child: IgnorePointer(
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_revision),
                  tween: Tween(begin: 0, end: 1),
                  duration: DesktopMotion.duration(
                    context,
                    DesktopMotion.detail,
                  ),
                  curve: Curves.easeOut,
                  builder: (_, value, child) => Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 6 * (1 - value)),
                      child: child,
                    ),
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width - 30,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: c.paper,
                        border: Border.all(color: c.line),
                        borderRadius: BorderRadius.circular(9),
                        boxShadow: [
                          if (DesktopMotion.enabled(context))
                            c.popupElevation
                          else
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .12),
                              blurRadius: 28,
                              offset: const Offset(0, 7),
                            ),
                        ],
                      ),
                      child: Text(
                        _message!,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall!.copyWith(color: c.ink),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
