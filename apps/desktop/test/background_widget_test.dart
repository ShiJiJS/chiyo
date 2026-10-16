import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  testWidgets(
    'unavailable background entry keeps window reachable; notification denial leaves pending approvals usable',
    (tester) async {
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
      await tester.tap(find.text('开启或检查提醒'));
      await tester.pump();
      expect(native.permissionRequests, 1);
      expect(find.text('请在系统设置中允许本应用发送通知，然后重试。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
    },
  );
}
