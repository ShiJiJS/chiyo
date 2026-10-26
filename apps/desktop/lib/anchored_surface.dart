import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui_palette.dart';
import 'desktop_motion.dart';

class AnchoredSurfaceController {
  VoidCallback? close;
}

/// One-sided popup. The selected row never moves the popup over its trigger.
Future<T?> showAnchoredSurface<T>(
  BuildContext context, {
  required Widget Function(BuildContext) builder,
  double width = 280,
  double height = 320,
  AnchoredSurfaceController? controller,
}) async {
  Tooltip.dismissAllToolTips();
  final box = context.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()!
          as RenderBox;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final originalSize = overlay.size;
  final sourceScroll = Scrollable.maybeOf(context)?.position;
  final sourceFocus = FocusManager.instance.primaryFocus;
  // The trigger may disappear while the route closes. Transition frames must
  // not look up ancestors through that removed context.
  final usesMotion = DesktopMotion.enabled(context);
  BuildContext? popup;
  var closing = false;
  void close() {
    if (closing || !(popup?.mounted ?? false)) return;
    // A route remains mounted during its exit animation. Repeated scroll or
    // resize notifications must not pop the underlying editor as well.
    if (ModalRoute.of(popup!)?.isCurrent != true) return;
    closing = true;
    Navigator.of(popup!).pop();
  }

  controller?.close = close;
  sourceScroll?.addListener(close);
  try {
    return await showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭菜单',
      barrierColor: Colors.transparent,
      transitionDuration: DesktopMotion.duration(context, DesktopMotion.menu),
      pageBuilder: (_, _, _) => LayoutBuilder(
        builder: (popupContext, bounds) {
          popup = popupContext;
          final screen = bounds.biggest;
          if (screen != originalSize) {
            WidgetsBinding.instance.addPostFrameCallback((_) => close());
          }
          final below = math.max(0.0, screen.height - anchor.bottom - 18);
          final above = math.max(0.0, anchor.top - 18);
          final goesDown =
              below >= height || (above < height && below >= above);
          final popupHeight = math.min(height, goesDown ? below : above);
          final popupWidth = math.min(
            math.max(width, anchor.width),
            screen.width - 24,
          );
          final left = anchor.left.clamp(
            12.0,
            math.max(12.0, screen.width - popupWidth - 12),
          );
          final top = goesDown
              ? anchor.bottom + 6
              : anchor.top - popupHeight - 6;
          final c = UiPalette.of(popupContext);
          return CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
            child: Stack(
              children: [
                Positioned(
                  left: left.toDouble(),
                  top: top,
                  width: popupWidth,
                  height: popupHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(usesMotion ? 8 : 7),
                      boxShadow: usesMotion
                          ? [
                              BoxShadow(
                                color: c.brightness == Brightness.dark
                                    ? const Color(0x55000000)
                                    : const Color(0x20243047),
                                offset: Offset(
                                  0,
                                  c.brightness == Brightness.dark ? 12 : 9,
                                ),
                                blurRadius: c.brightness == Brightness.dark
                                    ? 36
                                    : 32,
                              ),
                            ]
                          : const [],
                    ),
                    child: Material(
                      color: c.paper,
                      elevation: usesMotion ? 0 : 4,
                      shadowColor: const Color(0x22000000),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(usesMotion ? 8 : 7),
                        side: BorderSide(color: c.line),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: builder(popupContext),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      transitionBuilder: (_, animation, _, child) {
        if (!usesMotion) {
          return FadeTransition(opacity: animation, child: child);
        }
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (_, child) {
            final value = Curves.easeOut.transform(animation.value);
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, -3 * (1 - value)),
                child: child,
              ),
            );
          },
        );
      },
    );
  } finally {
    sourceScroll?.removeListener(close);
    controller?.close = null;
    if (sourceFocus?.context?.mounted ?? false) sourceFocus!.requestFocus();
  }
}
