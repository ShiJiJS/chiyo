import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/settings_page.dart';

void main() {
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
    await tester.pumpWidget(const PreviewWorkspace());
    await tester.pumpAndSettle();
  }

  Future<void> guide(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('preview-guide')));
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(DesktopDialog)))!;
    for (
      var frame = 0;
      frame < 30 && route.animation!.status != AnimationStatus.completed;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(route.animation!.status, AnimationStatus.completed);
  }

  Future<void> scenario(WidgetTester tester, String name) async {
    await guide(tester);
    final target = find.byKey(ValueKey('preview-scenario-$name'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    // Wait for the modal to be removed, not for the ongoing loading spinner.
    await tester.pump();
    for (
      var frame = 0;
      frame < 30 &&
          (find.byType(DesktopDialog).evaluate().isNotEmpty ||
              tester
                      .widget<DesktopButton>(
                        find.byKey(const ValueKey('preview-guide')),
                      )
                      .onPressed ==
                  null);
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(DesktopDialog), findsNothing);
    expect(
      tester
          .widget<DesktopButton>(find.byKey(const ValueKey('preview-guide')))
          .onPressed,
      isNotNull,
    );
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

  testWidgets(
    'theme, empty, error/retry and waiting recover through visible controls',
    (tester) async {
      await start(tester, width: 1280);
      await guide(tester);
      await tester.tap(find.byKey(const ValueKey('preview-theme-dark')));
      await tester.pumpAndSettle();
      final context = tester.element(
        find.byKey(const ValueKey('preview-guide')),
      );
      expect(UiPalette.of(context).brightness, Brightness.dark);
      await scenario(tester, 'empty');
      await tester.pumpAndSettle();
      expect(find.text('暂无资料'), findsOneWidget);
      await scenario(tester, 'failure');
      await tester.pumpAndSettle();
      expect(find.text('暂时无法读取资料，请重试。'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('15 项'), findsOneWidget);
      await scenario(tester, 'waiting');
      expect(find.text('正在更新…'), findsOneWidget);
      await scenario(tester, 'ready');
      await tester.pumpAndSettle();
      expect(find.text('正在更新…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'menu opens on one side, keyboard selects, Escape restores focus',
    (tester) async {
      await start(tester);
      await guide(tester);
      final select = find.descendant(
        of: find.byType(DesktopDialog),
        matching: find.byType(DesktopSelect<String>),
      );
      await tester.ensureVisible(select);
      final anchor = tester.getRect(select);
      await tester.tap(find.text('文本'));
      await tester.pumpAndSettle();
      final first = tester.getRect(find.text('文本').last);
      final last = tester.getRect(find.text('文件'));
      expect(first.top >= anchor.bottom || last.bottom <= anchor.top, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('多行文本'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsNothing);
      final button = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<DesktopButton>();
      expect(button?.key, const ValueKey('preview-guide'));
    },
  );

  testWidgets('large text can scroll the modal without obscuring actions', (
    tester,
  ) async {
    await start(tester, width: 1280, scale: 2);
    await guide(tester);
    final reset = find.text('重置预览资料');
    final done = find.text('完成');
    expect(tester.getRect(reset).bottom, lessThan(900));
    expect(tester.getRect(done).bottom, lessThan(900));
    await tester.ensureVisible(find.text('字段形式'));
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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

  testWidgets(
    'a shared refresh preserves the editing selection and active IME composition',
    (tester) async {
      await start(tester);
      await guide(tester);
      final input = find.byKey(const ValueKey('preview-text-input'));
      await tester.ensureVisible(input);
      await tester.showKeyboard(input);
      final controller = tester.widget<TextField>(input).controller!;
      final composing = TextEditingValue(
        text: controller.text,
        selection: const TextSelection(baseOffset: 2, extentOffset: 4),
        composing: const TextRange(start: 0, end: 5),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      final source = tester
          .widget<ZhiyuApp>(find.byType(ZhiyuApp))
          .controller
          .source;
      final other = await source.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
      );
      await source.saveRecord(
        WorkspaceEdit(
          operationId: 'ime-other-record-refresh',
          expectedVersion: other.version,
          record: other.record.copyWith(name: '另一条资料的修改'),
          values: {},
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.value, composing);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文组合输入已提交',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      await tester.pump();
      expect(controller.text, '中文组合输入已提交');
      expect(controller.value.composing, TextRange.empty);
    },
  );

  testWidgets(
    'a failed sample save preserves the draft and explicit retry updates shared data',
    (tester) async {
      await start(tester);
      await guide(tester);
      final input = find.byKey(const ValueKey('preview-text-input'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '日本服务器 · 新草稿');
      await tester.ensureVisible(find.text('下次保存失败'));
      await tester.tap(find.text('下次保存失败'));
      await tester.ensureVisible(find.byKey(const ValueKey('preview-action')));
      await tester.tap(find.byKey(const ValueKey('preview-action')));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，输入已保留，请重试。'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, '日本服务器 · 新草稿');
      expect(find.text('已保存到预览资料'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('preview-action')));
      await tester.pumpAndSettle();
      expect(find.text('已保存到预览资料'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await guide(tester);
      expect(tester.widget<TextField>(input).controller!.text, '日本服务器 · 新草稿');
    },
  );
}
