import 'package:flutter/material.dart';
import 'ui_palette.dart';
export 'prototype_icons.dart';

/// Chromium's native select caret, distinct from the SVG chevron symbol.
class PrototypeSelectCaret extends StatelessWidget {
  const PrototypeSelectCaret({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 10,
    height: 10,
    child: CustomPaint(painter: _SelectCaret(UiPalette.of(context).ink)),
  );
}

class _SelectCaret extends CustomPainter {
  _SelectCaret(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(2, 3)
        ..lineTo(5.5, 6)
        ..lineTo(9, 3),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter,
    );
  }

  @override
  bool shouldRepaint(_SelectCaret old) => old.color != color;
}

TextStyle prototypeText(
  BuildContext context,
  double size, {
  Color? color,
  FontWeight weight = FontWeight.w400,
  double height = 1.5,
  String? family,
}) => TextStyle(
  fontFamily: family ?? 'ProductSans',
  fontFamilyFallback: const ['Songti SC', 'AppSans'],
  fontSize: size,
  fontWeight: weight,
  height: height,
  letterSpacing: 0,
  color: color ?? UiPalette.of(context).ink,
);

/// Removes Material's implicit minimum size while retaining focus/keyboard behavior.
ButtonStyle prototypeButton(
  BuildContext context, {
  double size = 12,
  EdgeInsets padding = EdgeInsets.zero,
  Color? foreground,
  Color? background,
  BorderSide side = BorderSide.none,
  double radius = 4,
  FontWeight weight = FontWeight.w400,
}) => TextButton.styleFrom(
  textStyle: prototypeText(context, size, weight: weight),
  foregroundColor: foreground ?? UiPalette.of(context).muted,
  backgroundColor: background,
  minimumSize: Size.zero,
  padding: padding,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: RoundedRectangleBorder(
    side: side,
    borderRadius: BorderRadius.circular(radius),
  ),
);

class PrototypeCheck extends StatelessWidget {
  const PrototypeCheck({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 17,
    this.disabledSelectedColor,
  });
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final double size;
  final Color? disabledSelectedColor;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Transform.scale(
      scale: size / 18,
      child: Checkbox(
        value: value,
        onChanged: onChanged,
        fillColor: disabledSelectedColor == null
            ? null
            : WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.disabled) &&
                        states.contains(WidgetState.selected)
                    ? disabledSelectedColor
                    : null,
              ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide(color: UiPalette.of(context).muted, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
    ),
  );
}

/// CSS small remains in a 14px parent's inline line box; keep its trailing space.
class PrototypeSelfDescription extends StatelessWidget {
  const PrototypeSelfDescription({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Transform.translate(
      offset: const Offset(0, 2),
      child: Text(
        '聊天名称和用途由 Agent 自述，仅供判断。',
        style: prototypeText(context, 12, color: UiPalette.of(context).muted),
      ),
    ),
  );
}
