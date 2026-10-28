import 'package:flutter/material.dart';

enum DesktopScrollbarStyle { overlay, legacy }

/// Host appearance only. Custom scroll areas can keep their own fixed lane.
class DesktopScrollbarScope extends InheritedWidget {
  const DesktopScrollbarScope({
    super.key,
    required this.style,
    required super.child,
  });
  final DesktopScrollbarStyle style;

  static DesktopScrollbarStyle of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopScrollbarScope>()
          ?.style ??
      DesktopScrollbarStyle.legacy;

  static double gutterOf(BuildContext context, double legacyGutter) =>
      of(context) == DesktopScrollbarStyle.overlay ? 0 : legacyGutter;

  @override
  bool updateShouldNotify(DesktopScrollbarScope oldWidget) =>
      style != oldWidget.style;
}

/// Keeps the scrollbar's hit region outside content, including hover/drag.
/// Explicit scrollbars keep their controller and paint outside this same lane.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior({this.scrollbarGutter = gutter});
  static const gutter = 16.0;
  final double scrollbarGutter;

  @override
  bool shouldNotify(ScrollBehavior oldDelegate) =>
      oldDelegate is! DesktopScrollBehavior ||
      scrollbarGutter != oldDelegate.scrollbarGutter ||
      super.shouldNotify(oldDelegate);

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final horizontal =
        axisDirectionToAxis(details.direction) == Axis.horizontal;
    final inset = Padding(
      padding: horizontal
          ? EdgeInsets.only(bottom: scrollbarGutter)
          : EdgeInsetsDirectional.only(end: scrollbarGutter),
      child: child,
    );
    final existing = context.findAncestorWidgetOfExactType<Scrollbar>();
    if (existing != null &&
        (existing.controller == null ||
            existing.controller == details.controller)) {
      return inset;
    }
    return Scrollbar(controller: details.controller, child: inset);
  }
}
