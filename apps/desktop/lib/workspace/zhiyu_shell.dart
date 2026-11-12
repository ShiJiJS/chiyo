import 'package:flutter/material.dart';
import '../desktop_button.dart';
import '../desktop_scroll.dart';
import '../ui_palette.dart';
import '../prototype_icons.dart';
import 'workspace_source.dart';

/// Shell knows navigation and summary counts, not their storage or execution.
class ZhiyuShell extends StatelessWidget {
  const ZhiyuShell({
    super.key,
    required this.page,
    required this.onNavigate,
    required this.child,
    this.summary,
    this.trailing,
    this.navigationEnabled = true,
  });
  final bool navigationEnabled;
  final WorkspacePage page;
  final ValueChanged<WorkspacePage> onNavigate;
  final WorkspaceSummary? summary;
  final Widget child;
  final Widget? trailing;

  Widget _destination(
    BuildContext context,
    WorkspacePage destination,
    bool compact,
    bool dense,
  ) {
    final c = UiPalette.of(context);
    final selected = destination == page;
    final count = switch (destination) {
      WorkspacePage.approvals => summary?.pending ?? 0,
      WorkspacePage.proposals => summary?.proposals ?? 0,
      _ => 0,
    };
    final glyph = switch (destination) {
      WorkspacePage.library => PrototypeIconGlyph.grid,
      WorkspacePage.approvals => PrototypeIconGlyph.inbox,
      WorkspacePage.proposals => PrototypeIconGlyph.plus,
      WorkspacePage.history => PrototypeIconGlyph.clock,
      WorkspacePage.settings => PrototypeIconGlyph.tune,
    };
    return Semantics(
      selected: selected,
      child: DesktopButton(
        key: ValueKey('workspace-nav-${destination.name}'),
        kind: DesktopButtonKind.quiet,
        selected: selected,
        fontSize: dense ? 13 : 14,
        leadingGap: 8,
        padding: EdgeInsets.symmetric(horizontal: dense ? 9 : 11, vertical: 8),
        leading: compact
            ? null
            : SizedBox(
                width: 19,
                // HTML keeps the inline SVG's baseline/descent in its span.
                // These line boxes come from the frozen cascade at 1x text.
                height: dense ? 24.796875 : 25.390625,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: PrototypeIcon(
                    glyph,
                    size: 19,
                    color: selected ? c.accent : c.ink,
                  ),
                ),
              ),
        onPressed: navigationEnabled ? () => onNavigate(destination) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(destination.label),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                key: ValueKey('workspace-count-${destination.name}'),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: c.selected,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Center(
                  heightFactor: 1,
                  widthFactor: 1,
                  child: Text(
                    '$count',
                    style: TextStyle(fontSize: 12, color: c.accent),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Scaffold(
      backgroundColor: c.canvas,
      body: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth <= 1050 || scale > 1.3;
              final dense = constraints.maxWidth <= 1300;
              final brand = Row(
                key: const ValueKey('zhiyu-brand'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 28,
                    height: 31.390625,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Image.asset(
                        'assets/branding/chiyo-icon.png',
                        width: 28,
                        height: 28,
                        cacheWidth: 128,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Text(
                    '知予',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ],
              );
              final navigation = ScrollConfiguration(
                behavior: const DesktopScrollBehavior().copyWith(
                  scrollbars: compact,
                ),
                child: SingleChildScrollView(
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final destination in WorkspacePage.values) ...[
                        if (destination.index > 0) const SizedBox(width: 3),
                        _destination(context, destination, compact, dense),
                      ],
                    ],
                  ),
                ),
              );
              return Container(
                key: const ValueKey('zhiyu-appbar'),
                constraints: const BoxConstraints(minHeight: 66),
                padding: EdgeInsets.symmetric(horizontal: dense ? 15 : 22),
                decoration: BoxDecoration(
                  color: c.paper,
                  border: Border(bottom: BorderSide(color: c.line)),
                ),
                child: compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              children: [
                                brand,
                                const Spacer(),
                                if (trailing != null)
                                  Flexible(child: trailing!),
                              ],
                            ),
                          ),
                          navigation,
                        ],
                      )
                    : SizedBox(
                        height: 65,
                        child: Row(
                          children: [
                            brand,
                            SizedBox(width: dense ? 12 : 22),
                            navigation,
                            const Spacer(),
                            ?trailing,
                          ],
                        ),
                      ),
              );
            },
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
