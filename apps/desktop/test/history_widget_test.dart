import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'shortening retention shows real counts and deletes only after confirmation',
    (tester) async {
      viewport(tester);
      var now = DateTime.utc(2026, 10, 1);
      final service = InformationService.fictional(clock: () => now);
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('Chat');
      final request = service.agent.request(session, 'Address', [field]);
      service.owner.approve(request.id, [field]);
      await service.agent.read(
        service.agent.claim(session, request.id).token,
        field,
      );
      now = now.add(const Duration(days: 31));
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录保留设置'));
      await tester.pumpAndSettle();
      Future<void> shorten() async {
        await tester.tap(find.byKey(const ValueKey('retention-90')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('30 天').last);
        await tester.pumpAndSettle();
      }

      await shorten();
      expect(find.textContaining('1 条授权、1 条访问记录、1 条请求记录'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(service.owner.auditRetentionDays, 90);
      expect((await service.owner.history()).grants, hasLength(1));
      await shorten();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(service.owner.auditRetentionDays, 30);
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      expect(find.text('暂无授权历史。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
  testWidgets(
    'history separates approved names and actual accesses then revokes the grant',
    (tester) async {
      viewport(tester);
      final service = InformationService.fictional();
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('Fictional chat');
      final request = service.agent.request(session, 'Address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      await service.agent.read(grant.token, field);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      expect(find.text('Fictional demo server'), findsOneWidget);
      expect(find.textContaining('demo.example.invalid'), findsNothing);
      await tester.tap(find.text('实际访问 1'));
      await tester.pumpAndSettle();
      expect(find.text('访问允许'), findsOneWidget);
      expect(find.text('Fictional demo server：Address'), findsOneWidget);
      await tester.tap(find.text('撤销授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await tester.pumpAndSettle();
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      expect(find.text('已撤销'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
}
