import 'package:flutter/material.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';

/// Round09's shared settings paper, with one scroll owner per destination.
class SettingsPageContent extends StatelessWidget {
  const SettingsPageContent({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.scrollKey,
    this.controller,
    this.entranceKey,
  });
  final String title, description;
  final List<Widget> children;
  final Key? scrollKey, entranceKey;
  final ScrollController? controller;
  static EdgeInsets paddingOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width <= 1300
      ? const EdgeInsets.all(28)
      : const EdgeInsets.symmetric(horizontal: 35, vertical: 34);
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: scrollKey,
    controller: controller,
    padding: paddingOf(context),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1020),
        child: DesktopEntrance(
          key: entranceKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsPageHeading(title: title, description: description),
              const SizedBox(height: 26),
              ...children,
            ],
          ),
        ),
      ),
    ),
  );
}

class SettingsPageHeading extends StatelessWidget {
  const SettingsPageHeading({
    super.key,
    required this.title,
    required this.description,
  });
  final String title, description;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(bottom: 25),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: libraryHeading(context, 26)),
        const SizedBox(height: 8),
        Text(
          description,
          style: libraryText(context, 14, color: UiPalette.of(context).muted),
        ),
      ],
    ),
  );
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 23),
      decoration: BoxDecoration(
        color: c.paper,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Miniature reading surfaces from the frozen theme chooser, independent of
/// the currently active application theme.
class SettingsThemePreview extends StatelessWidget {
  const SettingsThemePreview({super.key, required this.brightness});
  final Brightness brightness;
  @override
  Widget build(BuildContext context) {
    final p = UiPalette.zhiyu(brightness);
    return Container(
      height: MediaQuery.sizeOf(context).width <= 1000 ? 120 : 146,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.canvas,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: 16,
            child: Container(
              decoration: BoxDecoration(
                color: p.paper,
                border: Border(bottom: BorderSide(color: p.line)),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 16,
            bottom: 0,
            width: 53,
            child: Container(
              decoration: BoxDecoration(
                color: p.rail,
                border: Border(right: BorderSide(color: p.line)),
              ),
            ),
          ),
          Positioned(
            left: 65,
            right: 11,
            top: 26,
            bottom: 10,
            child: Container(
              decoration: BoxDecoration(
                color: p.paper,
                border: Border.all(color: p.line),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(73, 31, 18, 17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: .85,
                  child: Container(
                    height: 9,
                    decoration: BoxDecoration(
                      color: brightness == Brightness.dark
                          ? p.accent
                          : const Color(0xff8b76ad),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FractionallySizedBox(
                  widthFactor: .7,
                  child: Container(
                    height: 7,
                    decoration: BoxDecoration(
                      color: p.muted.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(2),
                    ),
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
