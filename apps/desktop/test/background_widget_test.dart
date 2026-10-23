import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  testWidgets(
    'native settings action restores the window and selects settings',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      final native = NativeDesktopFixture();
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await tester.runAsync(runtime.start);
      expect(native.navigationStates, [true]);
      await tester.pumpWidget(
        InformationApp(service: service, port: 0, runtime: runtime),
      );
      await tester.pumpAndSettle();
      await native.events!(DesktopEvent.closeWindow);
      expect(native.hidden, isTrue);
      await native.events!(DesktopEvent.openSettings);
      await tester.pumpAndSettle();
      expect(native.hidden, isFalse);
      expect(
        find.byKey(const ValueKey('settings-section-notifications')),
        findsOneWidget,
      );
      expect(runtime.openApprovalsRevision, 0);
      expect(native.permissionRequests, 0);
      await native.events!(DesktopEvent.openApprovals);
      await tester.pumpAndSettle();
      await native.events!(DesktopEvent.openSettings);
      await tester.pumpAndSettle();
      expect(runtime.openSettingsRevision, 2);
      expect(
        find.byKey(const ValueKey('settings-section-notifications')),
        findsOneWidget,
      );
      await native.events!(DesktopEvent.searchApprovals);
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: find.byKey(const ValueKey('inbox-search')),
        matching: find.byType(EditableText),
      );
      expect(search, findsOneWidget);
      expect(tester.widget<EditableText>(search).focusNode.hasFocus, isTrue);
      await tester.enterText(search, 'Synthetic search');
      await native.events!(DesktopEvent.openSettings);
      await tester.pumpAndSettle();
      await native.events!(DesktopEvent.searchApprovals);
      await tester.pumpAndSettle();
      expect(runtime.searchApprovalsRevision, 2);
      expect(
        tester.widget<EditableText>(search).controller.text,
        'Synthetic search',
      );
      expect(tester.widget<EditableText>(search).focusNode.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
      expect(native.navigationStates, [true, false]);
    },
  );

  testWidgets(
    'unavailable background entry keeps window reachable; notification denial leaves pending approvals usable',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      final native = NativeDesktopFixture()
        ..availability = const DesktopAvailability(
          tray: false,
          notifications: NotificationAvailability.denied,
        );
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await tester.runAsync(runtime.start);
      final session = service.agent.openSession('test chat');
      final request = service.agent.request(session, 'Need address', [
        const FieldRef('demo-server', 'host'),
      ]);
      await tester.pumpWidget(
        InformationApp(service: service, port: 47125, runtime: runtime),
      );
      expect(find.textContaining('托盘或菜单栏不可用'), findsOneWidget);
      expect(find.textContaining('系统通知已被拒绝'), findsOneWidget);
      expect(native.permissionRequests, 0);
      await native.events!(DesktopEvent.closeWindow);
      expect(native.hidden, isFalse);
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await native.events!(DesktopEvent.openApprovals);
      await tester.pumpAndSettle();
      expect(find.text('test chat'), findsWidgets);
      expect(service.agent.status(session, request.id)['status'], 'pending');
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-section-notifications')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启或检查提醒'));
      await tester.pump();
      expect(native.permissionRequests, 1);
      expect(find.text('请在系统设置中允许本应用发送通知，然后重试。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
    },
  );
}
