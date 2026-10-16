import 'package:flutter/material.dart';
export 'desktop_controls.dart';

abstract final class UiColors {
  static const ink = Color(0xff26272c);
  static const muted = Color(0xff666a73);
  static const canvas = Color(0xfffcfcfd);
  static const rail = Color(0xfff3f4f6);
  static const line = Color(0xffe1e3e7);
  static const green = Color(0xff28695f);
  static const selected = Color(0xffe7e9ed);
  static const danger = Color(0xffb44742);
}

ThemeData informationTheme() {
  const body = TextStyle(
    fontFamily: 'AppSans',
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.55,
    color: UiColors.ink,
  );
  final texts = TextTheme(
    displayLarge: body.copyWith(fontSize: 26, fontWeight: FontWeight.w500),
    displayMedium: body.copyWith(fontSize: 24, fontWeight: FontWeight.w500),
    displaySmall: body.copyWith(fontSize: 22, fontWeight: FontWeight.w500),
    headlineLarge: body.copyWith(fontSize: 22, fontWeight: FontWeight.w500),
    headlineMedium: body.copyWith(fontSize: 20, fontWeight: FontWeight.w500),
    headlineSmall: body.copyWith(fontSize: 18, fontWeight: FontWeight.w500),
    titleLarge: body.copyWith(fontSize: 18, fontWeight: FontWeight.w500),
    titleMedium: body.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
    titleSmall: body.copyWith(fontWeight: FontWeight.w500),
    bodyLarge: body,
    bodyMedium: body,
    bodySmall: body.copyWith(fontSize: 12, color: UiColors.muted),
    labelLarge: body,
    labelMedium: body,
    labelSmall: body.copyWith(fontSize: 12),
  );
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(5)),
  );
  final button = ButtonStyle(
    textStyle: const WidgetStatePropertyAll(body),
    minimumSize: const WidgetStatePropertyAll(Size(56, 32)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    ),
    shape: const WidgetStatePropertyAll(shape),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    animationDuration: const Duration(milliseconds: 110),
  );
  final controlInk = WidgetStateProperty.resolveWith<Color>(
    (states) => states.contains(WidgetState.disabled)
        ? UiColors.muted.withValues(alpha: .4)
        : UiColors.ink,
  );
  final secondaryInk = WidgetStateProperty.resolveWith<Color>(
    (states) => states.contains(WidgetState.disabled)
        ? UiColors.muted.withValues(alpha: .4)
        : UiColors.muted,
  );
  const border = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(5)),
    borderSide: BorderSide(color: Color(0xffcdd0d6)),
  );
  return ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.windows: DesktopPageTransitionsBuilder(),
        TargetPlatform.macOS: DesktopPageTransitionsBuilder(),
        TargetPlatform.linux: DesktopPageTransitionsBuilder(),
      },
    ),
    fontFamily: 'AppSans',
    textTheme: texts,
    primaryTextTheme: texts,
    colorScheme: const ColorScheme.light(
      primary: UiColors.green,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: UiColors.ink,
      onSurfaceVariant: UiColors.muted,
      outline: Color(0xffa5a8b0),
      outlineVariant: UiColors.line,
      error: UiColors.danger,
    ),
    scaffoldBackgroundColor: UiColors.canvas,
    visualDensity: VisualDensity.standard,
    dividerColor: UiColors.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: const Color(0x08747b88),
    focusColor: const Color(0x1628695f),
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    iconTheme: const IconThemeData(size: 17, color: UiColors.muted),
    appBarTheme: AppBarTheme(
      backgroundColor: UiColors.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: texts.titleMedium,
      iconTheme: const IconThemeData(size: 18, color: UiColors.ink),
    ),
    dividerTheme: const DividerThemeData(
      color: UiColors.line,
      thickness: 1,
      space: 1,
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(7)),
        side: BorderSide(color: UiColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        foregroundColor: controlInk,
        side: const WidgetStatePropertyAll(
          BorderSide(color: Color(0xffd4d7dd)),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button.copyWith(
        foregroundColor: secondaryInk,
        minimumSize: const WidgetStatePropertyAll(Size(40, 30)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: button.copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(30, 30)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
        iconSize: const WidgetStatePropertyAll(17),
        foregroundColor: secondaryInk,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xff747c89), width: 1.25),
      ),
      disabledBorder: border.copyWith(
        borderSide: const BorderSide(color: UiColors.line),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: UiColors.danger),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: UiColors.danger, width: 1.25),
      ),
      helperMaxLines: 2,
      errorMaxLines: 3,
      helperStyle: texts.bodySmall,
      errorStyle: texts.bodySmall!.copyWith(color: UiColors.danger),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      side: const BorderSide(color: Color(0xffa7abb3), width: 1),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      minVerticalPadding: 4,
      horizontalTitleGap: 10,
      minLeadingWidth: 20,
      titleTextStyle: texts.bodyMedium,
      subtitleTextStyle: texts.bodySmall,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: Colors.white,
      collapsedBackgroundColor: Colors.white,
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: UiColors.muted,
      collapsedIconColor: UiColors.muted,
      textColor: UiColors.ink,
      collapsedTextColor: UiColors.ink,
      childrenPadding: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: const Color(0x22000000),
      barrierColor: const Color(0x33000000),
      titleTextStyle: texts.titleMedium!.copyWith(fontSize: 16),
      contentTextStyle: texts.bodyMedium,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: UiColors.line),
      ),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(6),
        shadowColor: WidgetStatePropertyAll(Color(0x22000000)),
        side: WidgetStatePropertyAll(BorderSide(color: UiColors.line)),
        shape: WidgetStatePropertyAll(shape),
        maximumSize: WidgetStatePropertyAll(Size(640, 360)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: button.copyWith(
        alignment: Alignment.centerLeft,
        minimumSize: const WidgetStatePropertyAll(Size(140, 30)),
        foregroundColor: controlInk,
      ),
    ),
    chipTheme: ChipThemeData(
      labelStyle: texts.bodyMedium,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      shape: shape,
      side: const BorderSide(color: UiColors.line),
      backgroundColor: Colors.white,
      selectedColor: UiColors.selected,
      showCheckmark: true,
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: texts.bodySmall!.copyWith(color: Colors.white),
      decoration: BoxDecoration(
        color: UiColors.ink,
        borderRadius: BorderRadius.circular(4),
      ),
      waitDuration: const Duration(milliseconds: 450),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: UiColors.ink,
      shape: shape,
      contentTextStyle: TextStyle(
        fontFamily: 'AppSans',
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: Colors.white,
      ),
    ),
  );
}

class DesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const DesktopPageTransitionsBuilder();
  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => MediaQuery.disableAnimationsOf(context)
      ? child
      : FadeTransition(opacity: animation, child: child);
}

class PageHeading extends StatelessWidget {
  const PageHeading(
    this.title, {
    super.key,
    this.subtitle,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      );
      final controls = Wrap(spacing: 8, runSpacing: 8, children: actions);
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child:
            constraints.maxWidth <
                800 * (MediaQuery.textScalerOf(context).scale(14) / 14)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    controls,
                  ],
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: heading),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 20),
                    controls,
                  ],
                ],
              ),
      );
    },
  );
}

class QuietNotice extends StatelessWidget {
  const QuietNotice(this.text, {super.key, this.warning = false});
  final String text;
  final bool warning;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          warning ? Icons.error_outline : Icons.info_outline,
          size: 17,
          color: warning ? UiColors.danger : UiColors.muted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: warning ? UiColors.danger : null,
            ),
          ),
        ),
      ],
    ),
  );
}

class StatusLabel extends StatelessWidget {
  const StatusLabel(this.label, {super.key, this.active = false});
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? UiColors.green : UiColors.muted,
        ),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: active ? UiColors.green : UiColors.muted,
          ),
        ),
      ),
    ],
  );
}

class EmptyWorkspace extends StatelessWidget {
  const EmptyWorkspace({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: UiColors.muted),
            const SizedBox(height: 18),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class WorkspaceEntrance extends StatelessWidget {
  const WorkspaceEntrance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    child: child,
    builder: (context, value, child) => Opacity(
      opacity: .8 + .2 * value,
      child: Transform.translate(
        offset: Offset(0, 4 * (1 - value)),
        child: child,
      ),
    ),
  );
}

String uiTime(DateTime? value) {
  if (value == null) return '时间未知';
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
