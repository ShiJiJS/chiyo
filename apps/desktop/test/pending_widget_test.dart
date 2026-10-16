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
    await tester.tap(find.byKey(const ValueKey('request-lifetime')));
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
    final core = InformationService.fictional(
      clock: () => DateTime.utc(2026, 10, 16),
    );
    final session = core.agent.openSession('demo-chat');
    final request = core.agent.request(session, 'Need host', [
      const FieldRef('demo-server', 'host'),
    ]);
    await tester.pumpWidget(InformationApp(service: core, port: 47125));
    expect(find.text('待审批剩余：30 分 0 秒'), findsOneWidget);
    await tester.ensureVisible(find.text('拒绝申请'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拒绝申请'));
    await tester.pump();
    expect(core.agent.status(session, request.id)['status'], 'denied');
    expect(find.text('已拒绝'), findsOneWidget);
    expect(find.text('批准所选字段'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    core.close();
  });
}
