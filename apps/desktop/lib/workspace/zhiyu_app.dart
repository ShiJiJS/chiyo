import 'package:flutter/material.dart';
import '../desktop_feedback.dart';
import '../desktop_interaction_host.dart';
import '../desktop_scroll.dart';
import '../window_frame.dart';
import 'workspace_controller.dart';
import 'workspace_source.dart';
import 'zhiyu_shell.dart';
import 'zhiyu_theme.dart';

typedef WorkspacePageBuilder =
    Widget Function(BuildContext context, WorkspaceLocation location);

/// Composes real widgets with the caller's controller and data implementation.
/// No reference to sample data or the production bootstrap is allowed here.
class ZhiyuApp extends StatelessWidget {
  const ZhiyuApp({
    super.key,
    required this.controller,
    required this.pageBuilder,
    this.trailingBuilder,
    this.windowTitle = '知予',
  });
  final WorkspaceController controller;
  final WorkspacePageBuilder pageBuilder;
  final WidgetBuilder? trailingBuilder;
  final String windowTitle;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => MaterialApp(
      title: windowTitle,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const DesktopScrollBehavior(scrollbarGutter: 9),
      theme: zhiyuTheme(Brightness.light),
      darkTheme: zhiyuTheme(Brightness.dark),
      themeMode: controller.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      themeAnimationDuration: Duration.zero,
      builder: (_, child) => DesktopInteractionHost(
        child: DesktopWindowFrame(
          caption: windowTitle,
          child: DesktopFeedback(child: child!),
        ),
      ),
      home: Builder(
        builder: (context) => RepaintBoundary(
          key: const ValueKey('zhiyu-content'),
          child: ZhiyuShell(
            page: controller.location.page,
            navigationEnabled: !controller.navigationLocked,
            summary: controller.summary,
            onNavigate: controller.navigate,
            trailing: trailingBuilder?.call(context),
            child: pageBuilder(context, controller.location),
          ),
        ),
      ),
    ),
  );
}
