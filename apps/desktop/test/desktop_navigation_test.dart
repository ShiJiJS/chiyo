import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/ui.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  testWidgets(
    'navigation switches one selection immediately and pages share an origin',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      await tester.pumpWidget(InformationApp(service: service, port: 47125));
      await tester.pumpAndSettle();
      final headings = ['访问审批', '资料库', '录入与变更提案', '授权与访问记录', '设置'];

      void checkSelection(int active) {
        for (var i = 0; i < 5; i++) {
          final container = tester.widget<Container>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('nav-$i')),
                  matching: find.byType(Container),
                )
                .first,
          );
          expect(
            (container.decoration! as BoxDecoration).color,
            i == active
                ? UiPalette.of(
                    tester.element(find.byKey(ValueKey('nav-$i'))),
                  ).selected
                : Colors.transparent,
          );
        }
      }

      for (final i in [0, 1, 2, 3, 4, 2, 0]) {
        await tester.tap(find.byKey(ValueKey('nav-$i')));
        await tester.pump();
        checkSelection(i);
        for (final elapsed in [30, 30, 60]) {
          await tester.pump(Duration(milliseconds: elapsed));
          checkSelection(i);
        }
        await tester.pumpAndSettle();
        final title = find.descendant(
          of: find.byType(PageHeading),
          matching: find.text(i == 0 ? '请求收件箱' : headings[i]),
        );
        expect(title, findsOneWidget);
        expect(
          tester.getTopLeft(title).dy,
          greaterThan(
            tester.getBottomLeft(find.byKey(const ValueKey('nav-0'))).dy,
          ),
        );
      }
      expect(find.textContaining('开发预览'), findsNothing);
      expect(find.textContaining('请使用虚构资料'), findsNothing);
      expect(find.text('完全退出'), findsNothing);
      expect(find.text('备份与恢复'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      expect(find.text('完全退出'), findsOneWidget);
      expect(find.text('备份与恢复'), findsOneWidget);
      expect(find.textContaining('模板不保存字段值'), findsOneWidget);
      await tester.tap(find.text('管理录入模板'));
      await tester.pumpAndSettle();
      expect(find.text('录入模板'), findsOneWidget);
      expect(find.textContaining('修改模板不会修改已有资料或授权'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subpage-back')));
      await tester.pumpAndSettle();
      expect(find.text('管理录入模板'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );

  testWidgets(
    'notification settings show permission and test-delivery outcomes without changing access',
    (tester) async {
      final service = InformationService.fictional();
      final native = NativeDesktopFixture();
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await tester.runAsync(runtime.start);
      await tester.pumpWidget(
        InformationApp(service: service, port: 47125, runtime: runtime),
      );
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启或检查提醒'));
      await tester.pumpAndSettle();
      expect(native.permissionRequests, 1);
      expect(find.text('应用提醒已开启，可以发送一条测试通知检查显示情况。'), findsOneWidget);
      await tester.tap(find.text('发送测试通知'));
      await tester.pumpAndSettle();
      expect(native.notices, ['test']);
      expect(find.textContaining('测试通知已提交给系统'), findsOneWidget);
      native.deliveryAvailable = false;
      await tester.tap(find.text('发送测试通知'));
      await tester.pumpAndSettle();
      expect(find.textContaining('测试通知提交失败'), findsOneWidget);
      expect(find.text('上次通知提交失败'), findsOneWidget);
      expect(find.text('应用提醒已开启'), findsNothing);
      native.deliveryAvailable = true;
      await tester.tap(find.text('发送测试通知'));
      await tester.pumpAndSettle();
      expect(find.text('上次通知提交失败'), findsNothing);
      expect(find.text('应用提醒已开启'), findsOneWidget);
      native.availability = const DesktopAvailability(
        tray: true,
        notifications: NotificationAvailability.denied,
      );
      await tester.tap(find.text('开启或检查提醒'));
      await tester.pumpAndSettle();
      expect(find.text('请在系统设置中允许本应用发送通知，然后重试。'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '发送测试通知'),
            )
            .onPressed,
        isNull,
      );
      native.availability = const DesktopAvailability(
        tray: true,
        notifications: NotificationAvailability.unavailable,
      );
      await tester.tap(find.text('开启或检查提醒'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前无法使用系统通知'), findsOneWidget);
      expect(service.owner.requests, isEmpty);
      expect(native.terminated, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
    },
  );
}
