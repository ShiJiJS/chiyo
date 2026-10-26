import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

/// Shared semantic colors. Read through context so every open page, popup and
/// window frame rebuilds when the saved desktop preference changes.
@immutable
class UiPalette extends ThemeExtension<UiPalette> {
  const UiPalette({
    required this.accent,
    required this.strong,
    required this.selected,
    required this.rail,
    required this.canvas,
    required this.paper,
    required this.line,
    required this.muted,
    required this.ink,
    this.brightness = Brightness.light,
    this.accentForeground,
    this.navigation,
  });
  final Color accent, strong, selected, rail, canvas, paper, line, muted, ink;
  final Brightness brightness;
  final Color? accentForeground;
  final Color? navigation;
  Color get nav => navigation ?? rail;
  Color get onAccent => accentForeground ?? paper;
  Color get brand => strong;
  // Frozen Round09 timeline ring, fixed in both themes.
  Color get timelineRing => const Color(0xffd5cbdf);
  Color get success => brightness == Brightness.dark
      ? const Color(0xff8ecfb2)
      : const Color(0xff27735f);
  Color get danger => brightness == Brightness.dark
      ? const Color(0xfff0a39d)
      : const Color(0xffb54143);
  Color get warning => brightness == Brightness.dark
      ? const Color(0xffdfbc7d)
      : const Color(0xff8d651e);
  bool get isMono => accent == const Color(0xff333333);
  Color get statusAttention =>
      isMono ? const Color(0xff505055) : const Color(0xff986409);
  Color get statusLive =>
      isMono ? const Color(0xff505055) : const Color(0xff38694c);
  Color get noticeWarningBackground =>
      isMono ? const Color(0xfff4f4f5) : const Color(0xfffaf5e9);
  Color get noticeWarningBorder =>
      isMono ? const Color(0xffc6c6ca) : const Color(0xffe4d4b2);
  Color get noticeWarningInk =>
      isMono ? const Color(0xff3f3f44) : const Color(0xff745521);
  static UiPalette of(BuildContext context) =>
      Theme.of(context).extension<UiPalette>() ??
      forTheme(DesktopColorTheme.purple);

  /// The approved Round09 palette. Legacy preferences remain a separate
  /// persistence concern until the real-service integration stage.
  static UiPalette zhiyu(Brightness brightness) => brightness == Brightness.dark
      ? const UiPalette(
          accent: Color(0xffc2abea),
          strong: Color(0xffe4e7ef),
          selected: Color(0xff393147),
          rail: Color(0xff20242c),
          canvas: Color(0xff181b22),
          paper: Color(0xff242831),
          line: Color(0xff39414f),
          muted: Color(0xffa4aebf),
          ink: Color(0xffe4e7ef),
          brightness: Brightness.dark,
          accentForeground: Color(0xff241d31),
          navigation: Color(0xff2d333f),
        )
      : const UiPalette(
          accent: Color(0xff66528e),
          strong: Color(0xff242936),
          selected: Color(0xffede8f5),
          rail: Color(0xfff7f8fa),
          canvas: Color(0xfff1f2f5),
          paper: Color(0xffffffff),
          line: Color(0xffdce1e8),
          muted: Color(0xff586477),
          ink: Color(0xff242936),
          accentForeground: Color(0xffffffff),
          navigation: Color(0xffe9ecf1),
        );
  static UiPalette forTheme(DesktopColorTheme theme) {
    final values = switch (theme) {
      DesktopColorTheme.purple => [
        0xff82536b,
        0xff70435b,
        0xffeadfe6,
        0xfff9f5f8,
        0xfff4f2f3,
        0xfffffdfd,
        0xffe0d7de,
        0xff655a62,
        0xff362e34,
      ],
      DesktopColorTheme.green => [
        0xff296a53,
        0xff235b48,
        0xffe1ece4,
        0xfff3f8f4,
        0xffeff3ef,
        0xfffefffe,
        0xffd7e3da,
        0xff5b6d63,
        0xff283d33,
      ],
      DesktopColorTheme.blue => [
        0xff496ea1,
        0xff3b5d8d,
        0xffe0e9f5,
        0xfff3f6fb,
        0xfff0f3f7,
        0xfffefeff,
        0xffd7e0ed,
        0xff536477,
        0xff2c394d,
      ],
      DesktopColorTheme.mono => [
        0xff333333,
        0xff1f1f1f,
        0xffe2e2e4,
        0xfff6f6f7,
        0xffededee,
        0xffffffff,
        0xffd3d3d6,
        0xff5d5d62,
        0xff242427,
      ],
    };
    return UiPalette(
      accent: Color(values[0]),
      strong: Color(values[1]),
      selected: Color(values[2]),
      rail: Color(values[3]),
      canvas: Color(values[4]),
      paper: Color(values[5]),
      line: Color(values[6]),
      muted: Color(values[7]),
      ink: Color(values[8]),
    );
  }

  @override
  UiPalette copyWith({
    Color? accent,
    Color? strong,
    Color? selected,
    Color? rail,
    Color? canvas,
    Color? paper,
    Color? line,
    Color? muted,
    Color? ink,
    Brightness? brightness,
    Color? accentForeground,
    Color? navigation,
  }) => UiPalette(
    accent: accent ?? this.accent,
    strong: strong ?? this.strong,
    selected: selected ?? this.selected,
    rail: rail ?? this.rail,
    canvas: canvas ?? this.canvas,
    paper: paper ?? this.paper,
    line: line ?? this.line,
    muted: muted ?? this.muted,
    ink: ink ?? this.ink,
    brightness: brightness ?? this.brightness,
    accentForeground: accentForeground ?? this.accentForeground,
    navigation: navigation ?? this.navigation,
  );
  @override
  UiPalette lerp(covariant UiPalette? other, double t) => other == null
      ? this
      : UiPalette(
          accent: Color.lerp(accent, other.accent, t)!,
          strong: Color.lerp(strong, other.strong, t)!,
          selected: Color.lerp(selected, other.selected, t)!,
          rail: Color.lerp(rail, other.rail, t)!,
          canvas: Color.lerp(canvas, other.canvas, t)!,
          paper: Color.lerp(paper, other.paper, t)!,
          line: Color.lerp(line, other.line, t)!,
          muted: Color.lerp(muted, other.muted, t)!,
          ink: Color.lerp(ink, other.ink, t)!,
          brightness: t < .5 ? brightness : other.brightness,
          accentForeground: Color.lerp(onAccent, other.onAccent, t),
          navigation: Color.lerp(nav, other.nav, t),
        );
}
