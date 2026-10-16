import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'prototype_ui.dart';
import 'ui.dart';

Widget settingsAction(
  BuildContext context,
  String label,
  VoidCallback? action, {
  bool primary = false,
  Key? key,
  Widget? trailing,
}) => TextButton(
  key: key,
  onPressed: action,
  style: prototypeButton(
    context,
    size: 13,
    padding: EdgeInsets.symmetric(horizontal: primary ? 21 : 17, vertical: 11),
    weight: primary ? FontWeight.w600 : FontWeight.w400,
    foreground: primary
        ? UiPalette.of(context).paper
        : UiPalette.of(context).ink,
    background: primary
        ? UiPalette.of(context).accent
        : UiPalette.of(context).paper,
    side: BorderSide(
      color: primary
          ? UiPalette.of(context).accent
          : UiPalette.of(context).line,
    ),
  ),
  child: trailing == null
      ? Text(label)
      : Row(
          mainAxisSize: MainAxisSize.min,
          children: [Text(label), const SizedBox(width: 14), trailing],
        ),
);

class SettingsRow extends StatelessWidget {
  const SettingsRow(
    this.title,
    this.description, {
    super.key,
    required this.control,
    this.first = false,
  });
  final String title, description;
  final Widget control;
  final bool first;
  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: prototypeText(context, 15, weight: FontWeight.w500)),
        const SizedBox(height: 7),
        Text(
          description,
          style: prototypeText(
            context,
            13,
            color: UiPalette.of(context).muted,
            height: 1.8,
          ),
        ),
      ],
    );
    return Container(
      padding: EdgeInsets.only(top: first ? 0 : 22, bottom: 22),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
      ),
      child: LayoutBuilder(
        builder: (context, box) =>
            MediaQuery.textScalerOf(context).scale(14) > 20 ||
                box.maxWidth < 460
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [body, const SizedBox(height: 14), control],
              )
            : Row(
                children: [
                  Expanded(child: body),
                  const SizedBox(width: 28),
                  control,
                ],
              ),
      ),
    );
  }
}

class SettingsNotice extends StatelessWidget {
  const SettingsNotice(
    this.title,
    this.message, {
    super.key,
    this.warning = false,
    this.error = false,
    this.icon = PrototypeIconGlyph.shield,
    this.verticalPadding = 16,
    this.textOffset = 0,
    this.lineGap = 3,
  });
  final String title, message;
  final bool warning, error;
  final PrototypeIconGlyph icon;
  final double verticalPadding;
  final double textOffset, lineGap;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final ink = error
        ? c.danger
        : warning
        ? c.noticeWarningInk
        : c.ink;
    return Container(
      margin: const EdgeInsets.only(top: 22),
      padding: EdgeInsets.symmetric(horizontal: 19, vertical: verticalPadding),
      decoration: BoxDecoration(
        color: warning ? c.noticeWarningBackground : c.rail,
        border: Border.all(color: warning ? c.noticeWarningBorder : c.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: PrototypeIcon(icon, color: error ? c.danger : c.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Transform.translate(
              offset: Offset(0, textOffset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: prototypeText(
                      context,
                      13,
                      height: 1.9,
                      color: ink,
                      weight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: lineGap),
                  Text(
                    message,
                    style: prototypeText(context, 13, height: 1.9, color: ink),
                  ),
                  SizedBox(height: 3 - lineGap),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> showSettingsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭对话框',
  barrierColor: const Color(0x4f241b27),
  pageBuilder: (context, animation, secondaryAnimation) => BackdropFilter(
    filter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
    child: builder(context),
  ),
);

class SettingsDialog extends StatelessWidget {
  const SettingsDialog({
    super.key,
    required this.title,
    required this.child,
    required this.actions,
    this.flow = false,
    this.busy = false,
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  final bool flow, busy;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), screen = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: flow ? 780 : 590,
        constraints: BoxConstraints(
          maxHeight: flow ? screen.height - 64 : screen.height * .85,
        ),
        padding: EdgeInsets.fromLTRB(32, 28, flow ? 47 : 32, 28),
        decoration: BoxDecoration(
          color: c.paper,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(9),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33211a26),
              offset: Offset(0, 20),
              blurRadius: 80,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: prototypeText(
                      context,
                      23,
                      family: 'SimSun',
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
                SizedBox.square(
                  dimension: 30,
                  child: TextButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    style: prototypeButton(context, size: 22),
                    child: const Text('×', textScaler: TextScaler.noScaling),
                  ),
                ),
              ],
            ),
            SizedBox(height: flow ? 14 : 20),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(right: 0, bottom: flow ? 16 : 0),
                child: child,
              ),
            ),
            if (actions.isNotEmpty)
              Container(
                margin: EdgeInsets.only(top: flow ? 0 : 26),
                padding: EdgeInsets.only(top: flow ? 16 : 0),
                decoration: flow
                    ? BoxDecoration(
                        border: Border(top: BorderSide(color: c.line)),
                      )
                    : null,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 10,
                  children: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
