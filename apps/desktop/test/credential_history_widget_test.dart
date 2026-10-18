import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'credential_use_widget_test.dart' show fixture;

void main() {
  testWidgets(
    'one mixed history entry preserves independent credential and field grants and links back to its credential',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final (service, session, request) = await fixture();
        try {
          await service.owner.decideCredentialUse(
            request.id,
            approveCredential: true,
            fields: request.fields,
          );
          final fieldGrant = service.agent.claim(session, request.id);
          await service.agent.read(fieldGrant.token, request.fields.single);
          await tester.pumpWidget(InformationApp(service: service, port: 0));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('nav-3')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(ValueKey('history-entry-${request.id}')),
            findsOneWidget,
          );
          expect(find.text('1 条记录'), findsOneWidget);
          expect(find.text('文档站发布 Token'), findsOneWidget);
          expect(find.text('GH_TOKEN'), findsOneWidget);
          expect(find.text('同时批准读取的连接字段'), findsOneWidget);
          expect(find.textContaining('synthetic-token'), findsNothing);
          await tester.tap(find.text('撤销使用授权'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认撤销'));
          await tester.pumpAndSettle();
          expect(
            service.owner.credentialGrantState(
              service.owner.credentialUseRequests.single,
            ),
            'revoked',
          );
          expect(
            await service.agent.read(fieldGrant.token, request.fields.single),
            'test.example.invalid',
          );
          await tester.ensureVisible(find.text('查看凭据 →'));
          await tester.tap(find.text('查看凭据 →'));
          await tester.pumpAndSettle();
          expect(find.text('文档站发布 Token'), findsWidgets);
          await tester.ensureVisible(find.text('查看使用记录 →'));
          await tester.tap(find.text('查看使用记录 →'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(ValueKey('history-document-${request.id}')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await service.close();
        }
      });
    },
  );
}
