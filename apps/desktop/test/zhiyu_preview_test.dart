import 'support/workspace_fixtures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/settings_page.dart';

void main() {
  for (final brightness in Brightness.values) {
    test(
      'Round09 semantic inks and popup elevation match the frozen theme ${brightness.name}',
      () {
        final c = UiPalette.zhiyu(brightness),
            dark = brightness == Brightness.dark;
        expect(c.success, Color(dark ? 0xff8ecfb2 : 0xff27765c));
        expect(c.warning, Color(dark ? 0xffdfbc7d : 0xff865a20));
        expect(c.danger, Color(dark ? 0xfff0a39d : 0xffab4c49));
        expect(
          c.popupElevation,
          BoxShadow(
            color: Color(dark ? 0x55000000 : 0x20243047),
            offset: Offset(0, dark ? 12 : 9),
            blurRadius: dark ? 36 : 32,
          ),
        );
        expect(c.copyWith().danger, c.danger);
      },
    );
  }
  Future<void> start(
    WidgetTester tester, {
    double width = 1440,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      const PreviewWorkspace(inputsBuilder: fixtureInputs),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one shell has five working destinations and a 66px appbar', (
    tester,
  ) async {
    await start(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('zhiyu-appbar'))).height,
      66,
    );
    for (final page in [
      'library',
      'approvals',
      'proposals',
      'history',
      'settings',
    ]) {
      await tester.tap(find.byKey(ValueKey('workspace-nav-$page')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<ZhiyuApp>(find.byType(ZhiyuApp))
            .controller
            .location
            .page
            .name,
        page,
      );
    }
    expect(find.byType(WorkspaceSettingsPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-section-plugins')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginsPage), findsOneWidget);
    expect(
      tester
          .widget<PluginsPage>(find.byType(PluginsPage))
          .controller
          .catalog!
          .packages,
      hasLength(3),
    );
    expect(find.byKey(const ValueKey('plugin-workspace')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('zhiyu-appbar'))).height,
      66,
    );
  });

  testWidgets('Escape respects a form that is blocking accidental dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: zhiyuTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => DesktopButton(
              onPressed: () => showDesktopDialog<void>(
                context,
                builder: (dialogContext) => PopScope(
                  canPop: false,
                  child: DesktopDialog(
                    title: const Text('未保存的表单'),
                    content: const Text('保留输入'),
                    actions: [
                      DesktopButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('明确放弃'),
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('保留输入'), findsOneWidget);
    await tester.tap(find.text('明确放弃'));
    await tester.pumpAndSettle();
    expect(find.text('保留输入'), findsNothing);
  });

  testWidgets(
    'pressed motion is transient and disabled actions do not execute',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: Center(
              child: DesktopButton(
                onPressed: () => calls++,
                child: const Text('操作'),
              ),
            ),
          ),
        ),
      );
      final text = find.text('操作');
      final before = tester.getTopLeft(text);
      final press = await tester.startGesture(tester.getCenter(text));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getTopLeft(text).dy - before.dy, closeTo(1, .01));
      await press.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(text).dy, closeTo(before.dy, .01));
      expect(calls, 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: const Scaffold(
            body: DesktopButton(onPressed: null, child: Text('不可用')),
          ),
        ),
      );
      await tester.tap(find.text('不可用'));
      expect(calls, 1);
    },
  );
}
