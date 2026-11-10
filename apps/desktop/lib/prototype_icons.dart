import 'package:flutter/widgets.dart';
import 'desktop_motion.dart';

/// Symbol IDs for the desktop's shared SVG icon geometry.
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
  grid,
  arrow,
  server,
  user,
  book,
  back,
  more,
  sort,
  expand,
  trash,
  plugin,
  globe,
  close,
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
            round09: DesktopMotion.enabled(context),
          ),
        ),
      ),
    );
  }
}

class _PrototypeIconPainter extends CustomPainter {
  const _PrototypeIconPainter(this.glyph, this.color, {this.round09 = false});

  final PrototypeIconGlyph glyph;
  final Color color;
  final bool round09;

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
      ..strokeWidth = round09 ? 1.7 : 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (round09 ||
        glyph == PrototypeIconGlyph.grid ||
        glyph == PrototypeIconGlyph.arrow ||
        glyph.index >= PrototypeIconGlyph.server.index) {
      canvas.drawPath(_round09Path(glyph), stroke);
      canvas.restore();
      return;
    }
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
      case PrototypeIconGlyph.grid:
      case PrototypeIconGlyph.arrow:
      case PrototypeIconGlyph.server:
      case PrototypeIconGlyph.user:
      case PrototypeIconGlyph.book:
      case PrototypeIconGlyph.back:
      case PrototypeIconGlyph.more:
      case PrototypeIconGlyph.sort:
      case PrototypeIconGlyph.expand:
      case PrototypeIconGlyph.trash:
      case PrototypeIconGlyph.plugin:
      case PrototypeIconGlyph.globe:
      case PrototypeIconGlyph.close:
        break; // Drawn through the approved Round09 path above.
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PrototypeIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.round09 != round09;
}

/// Paths from the frozen Round09 util.js; legacy callers retain their symbols.
Path _round09Path(PrototypeIconGlyph glyph) => switch (glyph) {
  PrototypeIconGlyph.close =>
    Path()
      ..moveTo(6, 6)
      ..lineTo(18, 18)
      ..moveTo(6, 18)
      ..lineTo(18, 6),
  PrototypeIconGlyph.plugin =>
    Path()
      ..moveTo(9, 3)
      ..lineTo(15, 3)
      ..lineTo(15, 8)
      ..lineTo(20, 8)
      ..lineTo(20, 14)
      ..lineTo(15, 14)
      ..lineTo(15, 21)
      ..lineTo(9, 21)
      ..lineTo(9, 14)
      ..lineTo(3, 14)
      ..lineTo(3, 8)
      ..lineTo(9, 8)
      ..close(),
  PrototypeIconGlyph.globe =>
    Path()
      ..addOval(const Rect.fromLTWH(2, 2, 20, 20))
      ..moveTo(2, 12)
      ..lineTo(22, 12)
      ..moveTo(12, 2)
      ..cubicTo(7, 7, 7, 17, 12, 22)
      ..moveTo(12, 2)
      ..cubicTo(17, 7, 17, 17, 12, 22),
  PrototypeIconGlyph.server =>
    Path()
      ..addRect(const Rect.fromLTWH(4, 3, 16, 7))
      ..addRect(const Rect.fromLTWH(4, 14, 16, 7))
      ..moveTo(7, 6.5)
      ..lineTo(7.01, 6.5)
      ..moveTo(7, 17.5)
      ..lineTo(7.01, 17.5)
      ..moveTo(11, 6.5)
      ..lineTo(17, 6.5)
      ..moveTo(11, 17.5)
      ..lineTo(17, 17.5),
  PrototypeIconGlyph.user =>
    Path()
      ..addOval(const Rect.fromLTWH(8, 3, 8, 8))
      ..moveTo(4, 21)
      ..lineTo(4, 18)
      ..arcToPoint(const Offset(20, 18), radius: const Radius.elliptical(8, 6))
      ..lineTo(20, 21),
  PrototypeIconGlyph.book =>
    Path()
      ..moveTo(3, 4)
      ..lineTo(9, 4)
      ..arcToPoint(const Offset(12, 7), radius: const Radius.circular(3))
      ..lineTo(12, 21)
      ..cubicTo(11, 19, 10, 19, 8, 19)
      ..lineTo(3, 19)
      ..close()
      ..moveTo(21, 4)
      ..lineTo(15, 4)
      ..arcToPoint(
        const Offset(12, 7),
        radius: const Radius.circular(3),
        clockwise: false,
      )
      ..lineTo(12, 21)
      ..cubicTo(13, 19, 14, 19, 16, 19)
      ..lineTo(21, 19)
      ..close(),
  PrototypeIconGlyph.back =>
    Path()
      ..moveTo(19, 12)
      ..lineTo(5, 12)
      ..moveTo(11, 6)
      ..lineTo(5, 12)
      ..lineTo(11, 18),
  PrototypeIconGlyph.more =>
    Path()
      ..moveTo(5, 12)
      ..lineTo(5.01, 12)
      ..moveTo(12, 12)
      ..lineTo(12.01, 12)
      ..moveTo(19, 12)
      ..lineTo(19.01, 12),
  PrototypeIconGlyph.sort =>
    Path()
      ..moveTo(8, 4)
      ..lineTo(8, 20)
      ..moveTo(4, 16)
      ..lineTo(8, 20)
      ..lineTo(12, 16)
      ..moveTo(14, 5)
      ..lineTo(20, 5)
      ..moveTo(14, 10)
      ..lineTo(18, 10)
      ..moveTo(14, 15)
      ..lineTo(16, 15),
  PrototypeIconGlyph.expand =>
    Path()
      ..moveTo(8, 3)
      ..lineTo(3, 3)
      ..lineTo(3, 8)
      ..moveTo(16, 3)
      ..lineTo(21, 3)
      ..lineTo(21, 8)
      ..moveTo(3, 16)
      ..lineTo(3, 21)
      ..lineTo(8, 21)
      ..moveTo(21, 16)
      ..lineTo(21, 21)
      ..lineTo(16, 21),
  PrototypeIconGlyph.trash =>
    Path()
      ..moveTo(3, 6)
      ..lineTo(21, 6)
      ..moveTo(9, 6)
      ..lineTo(9, 3)
      ..lineTo(15, 3)
      ..lineTo(15, 6)
      ..moveTo(5, 6)
      ..lineTo(6, 21)
      ..lineTo(18, 21)
      ..lineTo(19, 6)
      ..moveTo(10, 10)
      ..lineTo(10, 17)
      ..moveTo(14, 10)
      ..lineTo(14, 17),
  PrototypeIconGlyph.arrow =>
    Path()
      ..moveTo(5, 12)
      ..lineTo(19, 12)
      ..moveTo(13, 6)
      ..lineTo(19, 12)
      ..lineTo(13, 18),
  PrototypeIconGlyph.layers =>
    Path()
      ..moveTo(12, 3)
      ..lineTo(3, 8)
      ..lineTo(12, 13)
      ..lineTo(21, 8)
      ..close()
      ..moveTo(3, 12)
      ..lineTo(12, 17)
      ..lineTo(21, 12)
      ..moveTo(3, 16)
      ..lineTo(12, 21)
      ..lineTo(21, 16),
  PrototypeIconGlyph.grid =>
    Path()
      ..addRect(const Rect.fromLTWH(3, 3, 7, 7))
      ..addRect(const Rect.fromLTWH(14, 3, 7, 7))
      ..addRect(const Rect.fromLTWH(3, 14, 7, 7))
      ..addRect(const Rect.fromLTWH(14, 14, 7, 7)),
  PrototypeIconGlyph.inbox =>
    Path()
      ..addRect(const Rect.fromLTWH(3, 4, 18, 16))
      ..moveTo(3, 14)
      ..lineTo(8, 14)
      ..lineTo(10, 17)
      ..lineTo(14, 17)
      ..lineTo(16, 14)
      ..lineTo(21, 14),
  PrototypeIconGlyph.folder =>
    Path()
      ..moveTo(3, 5)
      ..lineTo(10, 5)
      ..lineTo(12, 8)
      ..lineTo(21, 8)
      ..lineTo(21, 21)
      ..lineTo(3, 21)
      ..close(),
  PrototypeIconGlyph.search =>
    Path()
      ..addOval(const Rect.fromLTWH(3, 3, 14, 14))
      ..moveTo(15, 15)
      ..lineTo(21, 21),
  PrototypeIconGlyph.clock =>
    Path()
      ..addOval(const Rect.fromLTWH(2, 2, 20, 20))
      ..moveTo(12, 6)
      ..lineTo(12, 12)
      ..lineTo(16, 15),
  PrototypeIconGlyph.plus =>
    Path()
      ..moveTo(12, 4)
      ..lineTo(12, 20)
      ..moveTo(4, 12)
      ..lineTo(20, 12),
  PrototypeIconGlyph.tune =>
    Path()
      ..moveTo(3, 6)
      ..lineTo(7, 6)
      ..moveTo(11, 6)
      ..lineTo(21, 6)
      ..moveTo(3, 18)
      ..lineTo(13, 18)
      ..moveTo(17, 18)
      ..lineTo(21, 18)
      ..moveTo(7, 3)
      ..lineTo(7, 9)
      ..moveTo(13, 15)
      ..lineTo(13, 21)
      ..moveTo(3, 12)
      ..lineTo(21, 12),
  PrototypeIconGlyph.chev =>
    Path()
      ..moveTo(9, 5)
      ..lineTo(16, 12)
      ..lineTo(9, 19),
  PrototypeIconGlyph.shield =>
    Path()
      ..moveTo(12, 2)
      ..lineTo(3, 6)
      ..lineTo(3, 12)
      ..cubicTo(3, 17, 12, 22, 12, 22)
      ..cubicTo(12, 22, 21, 17, 21, 12)
      ..lineTo(21, 6)
      ..close()
      ..moveTo(8, 11)
      ..lineTo(11, 14)
      ..lineTo(16, 8),
  PrototypeIconGlyph.link =>
    Path()
      ..moveTo(9, 15)
      ..lineTo(15, 9)
      ..moveTo(10, 7)
      ..lineTo(12, 5)
      ..cubicTo(17, 0, 24, 7, 19, 12)
      ..lineTo(17, 14)
      ..moveTo(14, 17)
      ..lineTo(12, 19)
      ..cubicTo(7, 24, 0, 17, 5, 12)
      ..lineTo(7, 10),
  PrototypeIconGlyph.file =>
    Path()
      ..moveTo(5, 2)
      ..lineTo(14, 2)
      ..lineTo(19, 7)
      ..lineTo(19, 22)
      ..lineTo(5, 22)
      ..close()
      ..moveTo(14, 2)
      ..lineTo(14, 8)
      ..lineTo(19, 8)
      ..moveTo(8, 12)
      ..lineTo(16, 12)
      ..moveTo(8, 16)
      ..lineTo(14, 16),
  PrototypeIconGlyph.edit =>
    Path()
      ..moveTo(15, 4)
      ..lineTo(20, 9)
      ..moveTo(4, 16)
      ..lineTo(16, 4)
      ..quadraticBezierTo(18, 2, 20, 4)
      ..quadraticBezierTo(22, 6, 20, 8)
      ..lineTo(8, 20)
      ..lineTo(4, 20)
      ..close(),
  PrototypeIconGlyph.key =>
    Path()
      ..addOval(const Rect.fromLTWH(4, 2, 10, 10))
      ..moveTo(13, 11)
      ..lineTo(21, 19)
      ..moveTo(16, 14)
      ..lineTo(19, 11)
      ..moveTo(19, 17)
      ..lineTo(22, 14),
};
