import 'package:flutter/widgets.dart';

/// Symbol IDs from docs/design/prototypes/round-05/index.html.
enum PrototypeIconGlyph {
  layers,
  inbox,
  folder,
  search,
  clock,
  plus,
  tune,
  chev,
  shield,
  link,
  file,
  edit,
  key,
}

/// An approved round-05 SVG icon, using its original 24-unit geometry.
///
/// The default size is 18 logical pixels, matching the prototype's global SVG
/// rule. Pass [size] for local overrides (for example, 26 for the brand), and
/// [color] to override the inherited [IconTheme] color. Like the HTML symbols,
/// these icons retain their direction and do not mirror in RTL layouts.
///
/// Icons beside visible text can omit [semanticLabel]. Give standalone icon
/// controls an accessible name on the control or through [semanticLabel].
class PrototypeIcon extends StatelessWidget {
  const PrototypeIcon(
    this.glyph, {
    super.key,
    this.size = 18,
    this.color,
    this.semanticLabel,
  }) : assert(size >= 0 && size < double.infinity);

  final PrototypeIconGlyph glyph;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final iconColor = color ?? iconTheme.color ?? const Color(0xff000000);
    final opacity = iconTheme.opacity ?? 1;
    return Semantics(
      label: semanticLabel,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _PrototypeIconPainter(
            glyph,
            opacity == 1
                ? iconColor
                : iconColor.withValues(alpha: iconColor.a * opacity),
          ),
        ),
      ),
    );
  }
}

class _PrototypeIconPainter extends CustomPainter {
  const _PrototypeIconPainter(this.glyph, this.color);

  final PrototypeIconGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // SVG's default preserveAspectRatio is xMidYMid meet.
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.translate(
      (size.width - 24 * scale) / 2,
      (size.height - 24 * scale) / 2,
    );
    canvas.scale(scale);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Keep separate SVG elements separate, including their original order.
    switch (glyph) {
      case PrototypeIconGlyph.layers:
        canvas.drawPath(
          Path()
            ..moveTo(12, 3)
            ..lineTo(21, 9)
            ..lineTo(12, 15)
            ..lineTo(3, 9)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(3, 14)
            ..lineTo(12, 20)
            ..lineTo(21, 14),
          stroke,
        );
      case PrototypeIconGlyph.inbox:
        canvas.drawPath(
          Path()
            ..moveTo(4, 4)
            ..lineTo(20, 4)
            ..lineTo(20, 20)
            ..lineTo(4, 20)
            ..close()
            ..moveTo(4, 13)
            ..lineTo(9, 13)
            ..lineTo(11, 16)
            ..lineTo(13, 16)
            ..lineTo(15, 13)
            ..lineTo(20, 13),
          stroke,
        );
      case PrototypeIconGlyph.folder:
        canvas.drawPath(
          Path()
            ..moveTo(3, 6)
            ..lineTo(10, 6)
            ..lineTo(12, 8)
            ..lineTo(21, 8)
            ..lineTo(21, 20)
            ..lineTo(3, 20)
            ..close(),
          stroke,
        );
      case PrototypeIconGlyph.search:
        canvas.drawCircle(const Offset(10, 10), 6, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(15, 15)
            ..lineTo(20, 20),
          stroke,
        );
      case PrototypeIconGlyph.clock:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(12, 7)
            ..lineTo(12, 12)
            ..lineTo(15, 14),
          stroke,
        );
      case PrototypeIconGlyph.plus:
        canvas.drawPath(
          Path()
            ..moveTo(12, 4)
            ..lineTo(12, 20)
            ..moveTo(4, 12)
            ..lineTo(20, 12),
          stroke,
        );
      case PrototypeIconGlyph.tune:
        canvas.drawPath(
          Path()
            ..moveTo(4, 7)
            ..lineTo(20, 7)
            ..moveTo(4, 17)
            ..lineTo(20, 17),
          stroke,
        );
        canvas.drawCircle(const Offset(8, 7), 2, stroke);
        canvas.drawCircle(const Offset(16, 17), 2, stroke);
      case PrototypeIconGlyph.chev:
        canvas.drawPath(
          Path()
            ..moveTo(9, 5)
            ..lineTo(16, 12)
            ..lineTo(9, 19),
          stroke,
        );
      case PrototypeIconGlyph.shield:
        canvas.drawPath(
          Path()
            ..moveTo(12, 3)
            ..lineTo(20, 6)
            ..lineTo(20, 12)
            ..cubicTo(20, 17, 12, 21, 12, 21)
            ..cubicTo(12, 21, 4, 17, 4, 12)
            ..lineTo(4, 6)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(8, 12)
            ..lineTo(11, 15)
            ..lineTo(16, 9),
          stroke,
        );
      case PrototypeIconGlyph.link:
        canvas.drawPath(
          Path()
            ..moveTo(10, 14)
            ..lineTo(14, 10)
            ..moveTo(8, 16)
            ..lineTo(7, 17)
            ..arcToPoint(const Offset(2, 12), radius: const Radius.circular(4))
            ..lineTo(6, 8)
            ..arcToPoint(const Offset(11, 8), radius: const Radius.circular(4))
            ..moveTo(16, 8)
            ..lineTo(17, 7)
            ..arcToPoint(const Offset(22, 12), radius: const Radius.circular(4))
            ..lineTo(18, 16)
            ..arcToPoint(
              const Offset(13, 16),
              radius: const Radius.circular(4),
            ),
          stroke,
        );
      case PrototypeIconGlyph.file:
        canvas.drawPath(
          Path()
            ..moveTo(5, 3)
            ..lineTo(14, 3)
            ..lineTo(19, 8)
            ..lineTo(19, 21)
            ..lineTo(5, 21)
            ..close()
            ..moveTo(14, 3)
            ..lineTo(14, 9)
            ..lineTo(19, 9)
            ..moveTo(8, 13)
            ..lineTo(16, 13)
            ..moveTo(8, 17)
            ..lineTo(14, 17),
          stroke,
        );
      case PrototypeIconGlyph.edit:
        canvas.drawPath(
          Path()
            ..moveTo(15, 4)
            ..lineTo(20, 9)
            ..lineTo(9, 20)
            ..lineTo(4, 20)
            ..lineTo(4, 15)
            ..close()
            ..moveTo(12, 7)
            ..lineTo(17, 12),
          stroke,
        );
      case PrototypeIconGlyph.key:
        canvas.drawCircle(const Offset(8, 9), 5, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(12, 13)
            ..lineTo(20, 21)
            ..moveTo(16, 17)
            ..lineTo(19, 14)
            ..moveTo(13, 14)
            ..lineTo(16, 11),
          stroke,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PrototypeIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
