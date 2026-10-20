import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets('settings change the lifetime of the next request', (
    tester,
  ) async {
    final core = InformationService.fictional();
    await tester.pumpWidget(InformationApp(service: core, port: 47125));
    await tester.tap(find.text('请求设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeout-30')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 分钟').last);
    await tester.pumpAndSettle();
    expect(core.owner.requestLifetime, const Duration(minutes: 5));
    await tester.pumpWidget(const SizedBox());
    core.close();
  });
  testWidgets('owner sees remaining time and rejects a pending request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = InformationService.fictional(
      clock: () => DateTime.utc(2026, 10, 16),
    );
    final session = core.agent.openSession('demo-chat');
    final request = core.agent.request(session, 'Need host', [
      const FieldRef('demo-server', 'host'),
    ]);
    await tester.pumpWidget(InformationApp(service: core, port: 47125));
    await tester.pumpAndSettle();
    final document = find.byKey(PageStorageKey('detail-${request.id}'));
    await tester.scrollUntilVisible(
      find.text('Need host'),
      100,
      scrollable: find
          .descendant(of: document, matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('Need host'), findsOneWidget);
    expect(find.text('还剩 30 分钟'), findsOneWidget);
    await tester.ensureVisible(find.text('拒绝请求'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拒绝请求'));
    await tester.pump();
    expect(core.agent.status(session, request.id)['status'], 'denied');
    expect(find.text('已拒绝'), findsWidgets);
    expect(find.text('批准所选字段'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    core.close();
  });
}
