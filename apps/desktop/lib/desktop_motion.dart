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
