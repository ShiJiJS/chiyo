import 'package:flutter/material.dart';

/// Keeps the scrollbar's hit region outside content, including hover/drag.
/// Explicit scrollbars keep their controller and paint outside this same lane.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior({this.scrollbarGutter = gutter});
  static const gutter = 16.0;
  final double scrollbarGutter;

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
