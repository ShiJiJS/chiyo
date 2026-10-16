import 'package:flutter/material.dart';

abstract final class UiColors {
  static const ink = Color(0xff202d29);
  static const muted = Color(0xff596b61);
  static const canvas = Color(0xfff8faf9);
  static const rail = Color(0xfff0f4f1);
  static const line = Color(0xffdfe7e2);
  static const green = Color(0xff19675d);
  static const selected = Color(0xffe3eee8);
  static const danger = Color(0xffa83d36);
}

ThemeData informationTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: const ColorScheme.light(
      primary: UiColors.green,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: UiColors.ink,
      onSurfaceVariant: UiColors.muted,
      outline: Color(0xff85968b),
      outlineVariant: UiColors.line,
      error: UiColors.danger,
    ),
    scaffoldBackgroundColor: UiColors.canvas,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(7));
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontSize: 23,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 21,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.5),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.5,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: 13,
        height: 1.5,
        color: UiColors.muted,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: UiColors.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: UiColors.line,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: shape.copyWith(side: const BorderSide(color: UiColors.line)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        side: const BorderSide(color: UiColors.line),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(40, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xfffafcfb),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: const BorderSide(color: UiColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: const BorderSide(color: UiColors.line),
      ),
      helperStyle: const TextStyle(
        fontSize: 12,
        height: 1.4,
        color: UiColors.muted,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      backgroundColor: Colors.white,
      collapsedBackgroundColor: Colors.white,
      shape: Border(),
      collapsedShape: Border(),
      iconColor: UiColors.green,
      textColor: UiColors.ink,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: UiColors.ink,
      shape: shape,
    ),
  );
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
