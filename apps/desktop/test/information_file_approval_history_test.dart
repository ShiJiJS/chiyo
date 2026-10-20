import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/history.dart';
import 'package:info_desktop/information_delivery_history.dart';
import 'package:info_desktop/ui.dart';
import 'support/information_attachment_fixture.dart';

void main() {
  testWidgets(
    'a later delivery remains discoverable after the older grant fact is pruned',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var now = DateTime.utc(2026, 1, 1);
        final f = await AttachmentUiFixture.create(clock: () => now);
        try {
          final session = f.service.agent.openSession('较晚的交付');
          final ref = FieldRef(f.item.id, f.item.fields.last.id);
          final request = f.service.agent.request(session, '读取简历', [ref]);
          f.owner.approve(request.id, [ref]);
          await f.owner.retryAuditStorage();
          now = now.add(const Duration(hours: 7));
          await f.fetch(session, request.id, 'later-file-operation');
          final id = f.owner.informationFileDeliveries.single.id;
          now = now.add(const Duration(days: 89, hours: 22));
          await f.owner.reconcileInformationFileDeliveries();
          await f.owner.history();
          await f.repository.pruneAudit(now.subtract(const Duration(days: 90)));
          expect((await f.owner.history()).grants, isEmpty);
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Scaffold(
                body: AuthorizationHistory(owner: f.owner, initialRecordId: id),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('原授权记录未保留'), findsOneWidget);
          expect(find.text('仅有交付事实'), findsOneWidget);
          await tester.enterText(
            find.byKey(const ValueKey('history-search')),
            'later-file-operation',
          );
          await tester.pumpAndSettle();
          expect(find.text('原授权记录未保留'), findsOneWidget);
          await tester.tap(find.textContaining('访问与交付'));
          await tester.pumpAndSettle();
          expect(find.text('简历 · 版本 1'), findsOneWidget);
          expect(find.textContaining('synthetic-private-path'), findsNothing);
          await expectLater(
            f.fetch(session, request.id, 'cannot-revive'),
            throwsA(isA<InformationFileFailure>()),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
        }
      });
    },
  );
  testWidgets(
    'mixed file approval rejects a changed review and delivery history keeps each version and cleanup outcome',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = await AttachmentUiFixture.create();
        final refresh = ValueNotifier(0);
        try {
          final session = f.service.agent.openSession('填写求职网站');
          final request = f.service.agent.request(
            session,
            '读取姓名与简历并填写个人资料',
            f.item.fields
                .map((field) => FieldRef(f.item.id, field.id))
                .toList(),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Scaffold(body: Approvals(service: f.service, port: 0)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('fictional-resume.pdf'), findsOneWidget);
          expect(find.textContaining('领取并读取原文件'), findsOneWidget);
          await tester.tap(
            find.byKey(ValueKey('field-${f.item.fields[1].id}')),
          );
          await tester.pumpAndSettle();
          final fieldId = f.item.fields.last.id;
          await f.replace([0, 255, 8, 9]);
          // Deliberately do not render again: the approval must use the displayed revision.
          await tester.tap(find.byKey(const ValueKey('approve-selection')));
          await tester.pumpAndSettle();
          expect(
            f.service.agent.status(session, request.id)['status'],
            'pending',
          );
          expect(find.textContaining('文件版本已变化'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('approve-selection')));
          await tester.pumpAndSettle();
          final grant = f.service.agent.claim(session, request.id);
          expect(
            grant.fields,
            unorderedEquals({
              FieldRef(f.item.id, f.item.fields.first.id),
              FieldRef(f.item.id, fieldId),
            }),
          );
          expect(
            f.owner.requests.single.grantLifetime,
            const Duration(hours: 8),
          );
          await f.fetch(session, request.id, 'first-copy');
          await f.replace([1, 2, 3]);
          await f.fetch(session, request.id, 'second-copy');
          final history = await f.owner.history();
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Scaffold(
                body: AuthorizationHistory(
                  owner: f.owner,
                  initialRecordId: history.grants.single.id,
                  refresh: refresh,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('简历（文件）'), findsOneWidget);
          await tester.tap(find.textContaining('访问与交付'));
          await tester.pumpAndSettle();
          expect(find.text('简历 · 版本 2'), findsOneWidget);
          expect(find.text('简历 · 版本 3'), findsOneWidget);
          expect(find.text('副本已就绪'), findsNWidgets(2));
          expect(find.textContaining('synthetic-private-path'), findsNothing);
          f.driver.blocked = true;
          f.owner.revoke(request.id);
          await f.service.agent.drainInformationFileDeliveries();
          refresh.value++;
          await tester.pumpAndSettle();
          expect(find.text('待回收副本'), findsNWidgets(2));
          f.driver.blocked = false;
          await tester.ensureVisible(find.text('重试回收'));
          await tester.tap(find.text('重试回收'));
          await tester.pumpAndSettle();
          expect(find.text('已失效'), findsNWidgets(2));
          expect(f.driver.bodies, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          refresh.dispose();
          await f.close();
        }
      });
    },
  );

  testWidgets(
    'archived file deliveries paginate and expose no runtime path or cleanup action',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = await AttachmentUiFixture.create();
        try {
          final session = f.service.agent.openSession('归档');
          final ref = FieldRef(f.item.id, f.item.fields.last.id);
          final request = f.service.agent.request(session, '读取简历', [ref]);
          f.owner.approve(request.id, [ref]);
          await f.owner.retryAuditStorage();
          await f.fetch(session, request.id, 'copy');
          final original = f.owner.informationFileDeliveries.single;
          final rows = [
            for (var i = 0; i < 12; i++)
              original.changed({
                'id': 'delivery-${i.toString().padLeft(2, '0')}',
                'operationId': 'operation-$i',
                'runtime': false,
                'sessionBinding': null,
                'lease': null,
                'restoredAt': DateTime.now().toUtc().toIso8601String(),
                if (i == 0) ...{
                  'state': 'cleanup_pending',
                  'targetState': 'expired',
                  'reason': 'not_authorized',
                  'cleanupError': 'cleanup_failed',
                  'finishedAt': DateTime.now().toUtc().toIso8601String(),
                },
              }),
          ];
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: InformationDeliveryHistory(records: rows),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Finder records() => find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('file-delivery-'),
          );
          expect(records(), findsNWidgets(8));
          expect(find.text('1 / 2'), findsOneWidget);
          expect(find.textContaining('历史：副本已就绪'), findsNWidgets(7));
          expect(find.text('历史：待回收副本'), findsOneWidget);
          expect(find.textContaining('副本仍被占用'), findsNothing);
          expect(find.textContaining('synthetic-private-path'), findsNothing);
          expect(find.text('重试回收'), findsNothing);
          await tester.ensureVisible(
            find.byKey(const ValueKey('file-deliveries-next')),
          );
          await tester.tap(find.byKey(const ValueKey('file-deliveries-next')));
          await tester.pumpAndSettle();
          expect(records(), findsNWidgets(4));
          expect(find.text('2 / 2'), findsOneWidget);
          expect(f.driver.sequence, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
        }
      });
    },
  );
}
