import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

/// The final round-05 modal surface. Callers own their draft and save behavior.
class PrototypeDialog extends StatelessWidget {
  const PrototypeDialog({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.onClose,
    this.flow = false,
    this.scrollGutter = 15,
    this.bottomPadding,
    this.bodyBottomPadding,
    this.width,
    this.simpleFlow = false,
    this.actionDivider = true,
    this.actionPaddingTop,
  });
  final String title;
  final Widget body;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final bool flow;
  final double scrollGutter;
  final double? bottomPadding;
  final double? bodyBottomPadding;
  final double? width;
  final bool actionDivider;
  final double? actionPaddingTop;

  /// Template-based credential flows keep the original unruled actions and
  /// nested bottom spacing; panel-based editors retain the separated footer.
  final bool simpleFlow;

  @override
  Widget build(BuildContext context) {
    final p = UiPalette.of(context);
    final viewport = MediaQuery.sizeOf(context);
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
      child: Center(
        child: Container(
          width: math.min(width ?? (flow ? 780 : 590), viewport.width - 48),
          constraints: BoxConstraints(
            maxHeight: flow ? viewport.height - 64 : viewport.height * .85,
          ),
          padding: EdgeInsets.fromLTRB(
            32,
            28,
            flow ? 47 : 32,
            bottomPadding ??
                (simpleFlow
                    ? 49
                    : flow
                    ? 34
                    : 28),
          ),
          decoration: BoxDecoration(
            color: p.paper,
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(9),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33211a26),
                offset: Offset(0, 20),
                blurRadius: 80,
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: title.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              title,
                              style: prototypeText(
                                context,
                                23,
                                family: 'SimSun',
                                weight: FontWeight.w500,
                              ),
                            ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(
                        top: math.max(
                          0,
                          (MediaQuery.textScalerOf(context).scale(23) * 1.5 -
                                  30) /
                              2,
                        ),
                      ),
                      child: SizedBox(
                        width: 30,
                        height: 30,
                        child: TextButton(
                          onPressed: onClose,
                          style: prototypeButton(
                            context,
                            size: 22,
                            iconOnly: true,
                          ),
                          child: const Text(
                            '×',
                            textScaler: TextScaler.noScaling,
                            semanticsLabel: '关闭',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: flow ? 13.5 : 20),
                Flexible(
                  child: SingleChildScrollView(
                    primary: false,
                    padding: EdgeInsets.only(
                      right: flow ? scrollGutter : 0,
                      bottom:
                          bodyBottomPadding ??
                          (simpleFlow
                              ? 14
                              : flow
                              ? 16
                              : 0),
                    ),
                    child: body,
                  ),
                ),
                if (actions.isNotEmpty)
                  Container(
                    padding: EdgeInsets.only(
                      top: simpleFlow
                          ? 0
                          : actionPaddingTop ?? (actionDivider ? 16 : 26),
                    ),
                    decoration: BoxDecoration(
                      border: simpleFlow || !actionDivider
                          ? null
                          : Border(top: BorderSide(color: p.line)),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 8,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

ButtonStyle prototypeSecondary(BuildContext context) => prototypeButton(
  context,
  size: 13,
  foreground: UiPalette.of(context).ink,
  background: UiPalette.of(context).paper,
  padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
  side: BorderSide(color: UiPalette.of(context).line),
);

ButtonStyle prototypePrimary(BuildContext context) => prototypeButton(
  context,
  size: 13,
  weight: FontWeight.w600,
  foreground: UiPalette.of(context).paper,
  background: UiPalette.of(context).accent,
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
);

Future<bool> prototypeConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  ModalRoute<bool>? confirmationRoute;
  final result = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) {
        confirmationRoute = ModalRoute.of<bool>(dialogContext);
        return PrototypeDialog(
        title: title,
        onClose: () => Navigator.pop(dialogContext, false),
        body: Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Text(message, style: prototypeText(context, 14, height: 1.9)),
        ),
        actions: [
          TextButton(
            style: prototypeSecondary(context),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: prototypePrimary(context),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      );
      },
    );
  await confirmationRoute?.completed;
  return result ?? false;
}
