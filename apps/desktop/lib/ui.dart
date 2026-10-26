import 'package:flutter/material.dart';
export 'desktop_controls.dart';
import 'package:info_core/info_core.dart';
import 'ui_palette.dart';
export 'ui_palette.dart';

abstract final class UiSpace {
  static const page = EdgeInsets.fromLTRB(24, 20, 24, 20);
}

abstract final class UiMotion {
  static const feedback = Duration(milliseconds: 160);
  static const panel = Duration(milliseconds: 180);
  static const entrance = Duration(milliseconds: 150);
}

ThemeData informationTheme([
  DesktopColorTheme colorTheme = DesktopColorTheme.purple,
]) => desktopTheme(palette: UiPalette.forTheme(colorTheme));

ThemeData desktopTheme({
  required UiPalette palette,
  TextStyle? typography,
  Duration feedbackDuration = UiMotion.feedback,
}) {
  final colors = palette;
  final body =
      typography ??
      TextStyle(
        fontFamily: 'ProductSans',
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.5,
        color: colors.ink,
      );
  final texts = TextTheme(
    displayLarge: body.copyWith(fontSize: 26, fontWeight: FontWeight.w500),
    displayMedium: body.copyWith(fontSize: 24, fontWeight: FontWeight.w500),
    displaySmall: body.copyWith(fontSize: 22, fontWeight: FontWeight.w500),
    headlineLarge: body.copyWith(fontSize: 22, fontWeight: FontWeight.w500),
    headlineMedium: body.copyWith(fontSize: 20, fontWeight: FontWeight.w500),
    headlineSmall: body.copyWith(fontSize: 18, fontWeight: FontWeight.w500),
    titleLarge: body.copyWith(fontSize: 20, fontWeight: FontWeight.w500),
    titleMedium: body.copyWith(fontSize: 16, fontWeight: FontWeight.w500),
    titleSmall: body.copyWith(fontWeight: FontWeight.w500),
    bodyLarge: body,
    bodyMedium: body,
    bodySmall: body.copyWith(fontSize: 13, color: colors.muted),
    labelLarge: body,
    labelMedium: body,
    labelSmall: body.copyWith(fontSize: 13),
  );
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(6)),
  );
  final button = ButtonStyle(
    textStyle: WidgetStatePropertyAll(body),
    minimumSize: WidgetStatePropertyAll(Size(64, 36)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    ),
    shape: WidgetStateProperty.resolveWith(
      (states) => RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        side:
            states.contains(WidgetState.focused) &&
                !states.contains(WidgetState.disabled)
            ? BorderSide(color: colors.ink, width: 2)
            : BorderSide.none,
      ),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    animationDuration: feedbackDuration,
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.pressed)) {
        return colors.accent.withValues(alpha: .13);
      }
      if (states.contains(WidgetState.hovered)) {
        return colors.accent.withValues(alpha: .06);
      }
      if (states.contains(WidgetState.focused)) {
        return colors.accent.withValues(alpha: .1);
      }
      return Colors.transparent;
    }),
  );
  final controlInk = WidgetStateProperty.resolveWith<Color>(
    (states) => states.contains(WidgetState.disabled)
        ? colors.muted.withValues(alpha: .4)
        : colors.ink,
  );
  final secondaryInk = WidgetStateProperty.resolveWith<Color>(
    (states) => states.contains(WidgetState.disabled)
        ? colors.muted.withValues(alpha: .4)
        : colors.muted,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(6)),
    borderSide: BorderSide(color: colors.line),
  );
  return ThemeData(
    extensions: [colors],
    useMaterial3: true,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        TargetPlatform.windows: DesktopPageTransitionsBuilder(),
        TargetPlatform.macOS: DesktopPageTransitionsBuilder(),
        TargetPlatform.linux: DesktopPageTransitionsBuilder(),
      },
    ),
    fontFamily: body.fontFamily,
    fontFamilyFallback: body.fontFamilyFallback,
    textTheme: texts,
    primaryTextTheme: texts,
    colorScheme: ColorScheme.light(
      primary: colors.accent,
      onPrimary: colors.onAccent,
      secondary: colors.accent,
      onSecondary: colors.onAccent,
      surface: colors.paper,
      surfaceContainerLow: colors.rail,
      onSurface: colors.ink,
      onSurfaceVariant: colors.muted,
      outline: colors.line,
      outlineVariant: colors.line,
      error: colors.danger,
    ).copyWith(brightness: colors.brightness),
    scaffoldBackgroundColor: colors.paper,
    visualDensity: VisualDensity.standard,
    dividerColor: colors.line,
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(true),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => colors.muted.withValues(
          alpha:
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? .7
              : .4,
        ),
      ),
      thickness: const WidgetStatePropertyAll(5),
      radius: const Radius.circular(4),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.accent,
      linearTrackColor: colors.line,
      circularTrackColor: colors.line,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: colors.accent.withValues(alpha: .11),
    hoverColor: colors.muted.withValues(alpha: .06),
    focusColor: colors.accent.withValues(alpha: .14),
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    iconTheme: IconThemeData(size: 17, color: colors.muted),
    dividerTheme: DividerThemeData(color: colors.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        foregroundColor: controlInk,
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? colors.accent
                : colors.line,
            width: states.contains(WidgetState.focused) ? 2 : 1,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button.copyWith(
        foregroundColor: secondaryInk,
        minimumSize: WidgetStatePropertyAll(Size(40, 34)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: button.copyWith(
        minimumSize: WidgetStatePropertyAll(Size(30, 30)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(5)),
        iconSize: WidgetStatePropertyAll(17),
        foregroundColor: secondaryInk,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.paper,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: colors.accent, width: 1.25),
      ),
      disabledBorder: border.copyWith(
        borderSide: BorderSide(color: colors.line),
      ),
      errorBorder: border.copyWith(
        borderSide: BorderSide(color: colors.danger),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: BorderSide(color: colors.danger, width: 1.25),
      ),
      helperMaxLines: 2,
      errorMaxLines: 3,
      helperStyle: texts.bodySmall,
      errorStyle: texts.bodySmall!.copyWith(color: colors.danger),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      side: BorderSide(color: Color(0xffa7abb3), width: 1),
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
      backgroundColor: colors.paper,
      collapsedBackgroundColor: colors.paper,
      shape: Border(),
      collapsedShape: Border(),
      iconColor: colors.muted,
      collapsedIconColor: colors.muted,
      textColor: colors.ink,
      collapsedTextColor: colors.ink,
      childrenPadding: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: Color(0x22000000),
      barrierColor: Color(0x33000000),
      titleTextStyle: texts.titleMedium!.copyWith(fontSize: 16),
      contentTextStyle: texts.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: colors.line),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.paper),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(6),
        shadowColor: WidgetStatePropertyAll(Color(0x22000000)),
        side: WidgetStatePropertyAll(BorderSide(color: colors.line)),
        shape: WidgetStatePropertyAll(shape),
        maximumSize: WidgetStatePropertyAll(Size(640, 360)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: button.copyWith(
        alignment: Alignment.centerLeft,
        minimumSize: WidgetStatePropertyAll(Size(140, 30)),
        foregroundColor: controlInk,
      ),
    ),
    chipTheme: ChipThemeData(
      labelStyle: texts.bodyMedium,
      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      shape: shape,
      side: BorderSide(color: colors.line),
      backgroundColor: colors.paper,
      selectedColor: colors.selected,
      showCheckmark: true,
    ),
    tooltipTheme: TooltipThemeData(
      constraints: const BoxConstraints(maxWidth: 320),
      textStyle: texts.bodySmall!.copyWith(color: colors.ink, height: 1.6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.all(8),
      verticalOffset: 8,
      preferBelow: false,
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x16000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      waitDuration: Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.ink,
      shape: shape,
      contentTextStyle: TextStyle(
        fontFamily: 'ProductSans',
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: colors.paper,
      ),
    ),
  );
}

class DesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const DesktopPageTransitionsBuilder();
  @override
  Duration get transitionDuration => UiMotion.feedback;
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
    builder: (context, bounds) {
      final titleText = Text(
        title,
        style: Theme.of(context).textTheme.titleLarge,
      );
      final controls = Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: actions,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bounds.maxWidth >= 700)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 36),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: titleText,
                      ),
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 20),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: bounds.maxWidth * .68,
                      ),
                      child: controls,
                    ),
                  ],
                ],
              )
            else
              titleText,
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (bounds.maxWidth < 700 && actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(alignment: Alignment.centerLeft, child: controls),
              ),
          ],
        ),
      );
    },
  );
}

class QuietNotice extends StatelessWidget {
  const QuietNotice(
    this.text, {
    super.key,
    this.warning = false,
    this.panel = false,
  });
  final String text;
  final bool warning;
  final bool panel;
  @override
  Widget build(BuildContext context) => panel
      ? Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 16),
          decoration: BoxDecoration(
            color: UiPalette.of(context).noticeWarningBackground,
            border: Border.all(
              color: UiPalette.of(context).noticeWarningBorder,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: UiPalette.of(context).noticeWarningInk,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.9,
                    color: UiPalette.of(context).noticeWarningInk,
                  ),
                ),
              ),
            ],
          ),
        )
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                warning ? Icons.error_outline : Icons.info_outline,
                size: 17,
                color: warning
                    ? UiPalette.of(context).danger
                    : UiPalette.of(context).muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: warning ? UiPalette.of(context).danger : null,
                  ),
                ),
              ),
            ],
          ),
        );
}

class StatusLabel extends StatelessWidget {
  const StatusLabel(
    this.label, {
    super.key,
    this.active = false,
    this.attention = false,
  });
  final String label;
  final bool active, attention;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? UiPalette.of(context).statusLive
              : attention
              ? UiPalette.of(context).statusAttention
              : UiPalette.of(context).muted,
        ),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: active
                ? UiPalette.of(context).statusLive
                : attention
                ? UiPalette.of(context).statusAttention
                : UiPalette.of(context).muted,
          ),
        ),
      ),
    ],
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.detail});
  final String title;
  final String? detail;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        if (detail != null)
          Text(detail!, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// Page width is owned by the shared shell, keeping every page on one grid.
class ReadingWorkspace extends StatelessWidget {
  const ReadingWorkspace({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

class DesktopSubpage extends StatelessWidget {
  const DesktopSubpage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.backLabel = '信息库',
  });
  final String title;
  final String backLabel;
  final Widget body;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Container(
          color: UiPalette.of(context).rail,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              TextButton.icon(
                key: const ValueKey('subpage-back'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: Text(backLabel),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...actions,
            ],
          ),
        ),
        const Divider(),
        Expanded(child: body),
      ],
    ),
  );
}

class EditorColumns extends StatelessWidget {
  const EditorColumns({
    super.key,
    required this.metadata,
    required this.content,
  });
  final Widget metadata, content;
  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= 1080 &&
        MediaQuery.textScalerOf(context).scale(14) <= 20;
    if (!wide) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          metadata,
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(),
          ),
          content,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 240, child: metadata),
        const SizedBox(width: 32),
        Expanded(child: content),
      ],
    );
  }
}

// Flat record rows and section surfaces are shared by all desktop workspaces.
class RecordSurface extends StatelessWidget {
  const RecordSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: child,
  );
}

class WorkspaceRecord extends StatelessWidget {
  const WorkspaceRecord({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final Widget title;
  final Widget? subtitle, trailing;
  @override
  Widget build(BuildContext context) => RecordSurface(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 4),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle(
                style: Theme.of(context).textTheme.titleSmall!,
                child: title,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                DefaultTextStyle(
                  style: Theme.of(context).textTheme.bodySmall!,
                  child: subtitle!,
                ),
              ],
            ],
          );
          if (bounds.maxWidth <
              640 * (MediaQuery.textScalerOf(context).scale(14) / 14)) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                if (trailing != null) ...[
                  const SizedBox(height: 12),
                  trailing!,
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: text),
              if (trailing != null) ...[const SizedBox(width: 24), trailing!],
            ],
          );
        },
      ),
    ),
  );
}

class FormSection extends StatelessWidget {
  const FormSection({
    super.key,
    required this.title,
    required this.child,
    this.detail,
    this.protected = false,
  });
  final String title;
  final String? detail;
  final Widget child;
  final bool protected;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: protected
          ? UiPalette.of(context).rail
          : UiPalette.of(context).paper,
      border: Border.all(color: UiPalette.of(context).line),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(title, detail: detail),
        child,
      ],
    ),
  );
}

class InformationValue extends StatefulWidget {
  const InformationValue({
    super.key,
    required this.name,
    required this.value,
    this.description,
    this.actions = const [],
  });
  final String name, value;
  final String? description;
  final List<Widget> actions;
  @override
  State<InformationValue> createState() => _InformationValueState();
}

class _InformationValueState extends State<InformationValue> {
  bool _expanded = false;
  @override
  void didUpdateWidget(covariant InformationValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name || oldWidget.value != widget.value) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.value.split('\n');
    final long = widget.value.length > 800 || lines.length > 8;
    final linePreview = lines.take(8).join('\n');
    final preview = linePreview.length > 800
        ? linePreview.substring(0, 800)
        : linePreview;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.name,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ...widget.actions,
            ],
          ),
          if (widget.description != null && widget.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                widget.description!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: UiPalette.of(context).rail,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  long && !_expanded ? '$preview…' : widget.value,
                  maxLines: long && !_expanded ? 8 : null,
                ),
                if (long)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      child: Text(_expanded ? '收起内容' : '展开完整内容'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
    child: SingleChildScrollView(
      primary: false,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: UiPalette.of(context).muted),
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
        : UiMotion.entrance,
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

double uiIconSize(BuildContext context, [double base = 17]) =>
    base * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 1.75);
