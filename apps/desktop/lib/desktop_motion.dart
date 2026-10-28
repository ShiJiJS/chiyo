import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Motion shared by the Round09 workspace and the existing desktop surfaces.
/// A missing extension preserves the legacy application's transitions.
@immutable
class DesktopMotion extends ThemeExtension<DesktopMotion> {
  const DesktopMotion();
  static const feedback = Duration(milliseconds: 150);
  static const detail = Duration(milliseconds: 180);
  static const menu = Duration(milliseconds: 120);
  static const dialog = Duration(milliseconds: 180);

  static bool enabled(BuildContext context) =>
      Theme.of(context).extension<DesktopMotion>() != null;
  static Duration duration(BuildContext context, Duration value) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
  static Duration feedbackOf(BuildContext context) => duration(
    context,
    enabled(context) ? feedback : const Duration(milliseconds: 160),
  );

  @override
  DesktopMotion copyWith() => this;
  @override
  DesktopMotion lerp(covariant DesktopMotion? other, double t) => other ?? this;
}

/// Key by the selected object's identity. Refreshing that object does not
/// replay its entrance, and an interrupted transition has no independent timer.
class DesktopEntrance extends StatelessWidget {
  const DesktopEntrance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: DesktopMotion.duration(context, DesktopMotion.detail),
    curve: Curves.easeOut,
    child: child,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 3 * (1 - value)),
        child: child,
      ),
    ),
  );
}

/// Frozen Round09 overlays animate on entry and close without an exit effect.
/// Keeping blur on the route barrier leaves the popup itself sharp and avoids
/// translating the filter region with the popup's 7px entrance.
class DesktopPopupRoute<T> extends RawDialogRoute<T> {
  DesktopPopupRoute({
    required super.pageBuilder,
    required super.barrierDismissible,
    required super.barrierLabel,
    required super.barrierColor,
    required super.transitionDuration,
    required super.transitionBuilder,
    required this.round09,
    bool blurBarrier = false,
  }) : _backdropFilter = round09 && blurBarrier
           ? ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2)
           : null;

  final bool round09;
  final ui.ImageFilter? _backdropFilter;
  @override
  ui.ImageFilter? get filter => _backdropFilter;
  @override
  Duration get reverseTransitionDuration =>
      round09 ? Duration.zero : super.reverseTransitionDuration;
}
