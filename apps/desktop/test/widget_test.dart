import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets('desktop approves only selected field then revokes the grant', (
    tester,
  ) async {
    final core = InformationService.fictional();
    final session = core.agent.openSession('demo-chat');
    final request = core.agent.request(session, 'Need address', [
      const FieldRef('demo-server', 'host'),
      const FieldRef('demo-server', 'username'),
    ]);
    await tester.pumpWidget(InformationApp(service: core, port: 47125));
    expect(find.text('Need address'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('field-username')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('field-username')));
    await tester.pump();
    await tester.ensureVisible(find.text('批准所选字段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批准所选字段'));
    await tester.pump();
    final grant = core.agent.claim(session, request.id);
    expect(grant.fields, [const FieldRef('demo-server', 'host')]);
    await tester.ensureVisible(find.text('撤销授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销授权'));
    await tester.pump();
    expect(
      () => core.agent.read(grant.token, const FieldRef('demo-server', 'host')),
      throwsA(isA<AccessFailure>()),
    );
    await tester.pumpWidget(const SizedBox());
    core.close();
  });
}
