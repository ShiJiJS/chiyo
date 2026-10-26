import 'package:flutter/material.dart';
import '../desktop_motion.dart';
import '../ui.dart';
import '../desktop_fonts.dart';

/// One source of visual values for the real widgets used by preview and,
/// later, production. No stored legacy preference is translated here.
ThemeData zhiyuTheme(Brightness brightness) {
  final palette = UiPalette.zhiyu(brightness);
  final base = desktopTheme(
    palette: palette,
    typography: TextStyle(
      fontFamily: desktopFontFamily,
      fontFamilyFallback: desktopFontFallback,
      fontSize: 14,
      height: 1.6,
      letterSpacing: 0,
      color: palette.ink,
    ),
    feedbackDuration: DesktopMotion.feedback,
  );
  return base.copyWith(
    extensions: [palette, const DesktopMotion()],
    scaffoldBackgroundColor: palette.canvas,
    iconTheme: IconThemeData(color: palette.muted, size: 18),
    scrollbarTheme: base.scrollbarTheme.copyWith(
      thumbColor: WidgetStatePropertyAll(
        brightness == Brightness.dark
            ? const Color(0xff566175)
            : const Color(0xffb4bcc9),
      ),
    ),
  );
}
