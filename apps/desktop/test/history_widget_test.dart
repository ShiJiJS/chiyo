import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/history.dart';

void main() {
  testWidgets(
    'shortening retention shows counts and only deletes after owner confirmation',
    (tester) async {
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AuthorizationHistory(owner: service.owner)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audit-retention')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 天').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条授权历史和 1 条访问记录'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(service.owner.auditRetentionDays, 90);
      expect((await service.owner.history()).grants, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('audit-retention')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 天').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(service.owner.auditRetentionDays, 30);
      expect(find.text('暂无授权历史。'), findsOneWidget);
      await service.close();
    },
  );
  testWidgets(
    'history shows approved names and linked results, then revokes actual grant',
    (tester) async {
      final service = InformationService.fictional();
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('Fictional chat');
      final request = service.agent.request(session, 'Address', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      await service.agent.read(grant.token, field);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AuthorizationHistory(owner: service.owner)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Fictional demo server · Address'),
        findsOneWidget,
      );
      expect(find.textContaining('读取获准'), findsOneWidget);
      expect(find.textContaining('demo.example.invalid'), findsNothing);
      await tester.tap(find.text('撤销授权'));
      await tester.pumpAndSettle();
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      expect(find.textContaining('已撤销'), findsOneWidget);
      await service.close();
    },
  );
}
