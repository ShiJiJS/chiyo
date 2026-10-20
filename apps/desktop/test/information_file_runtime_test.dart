import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/settings.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/ui.dart';
import 'support/information_attachment_fixture.dart';

void main() {
  Future<void> waitForCheck(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    do {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('正在核查…').evaluate().isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    } while (DateTime.now().isBefore(deadline));
    expect(find.text('正在核查…'), findsNothing);
  }

  testWidgets(
    'application settings explain a held ordinary file copy and retry only registered cleanup',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        var now = DateTime.utc(2026, 10, 19);
        final f = await AttachmentUiFixture.create(clock: () => now);
        try {
          final session = f.service.agent.openSession('回收测试');
          final ref = FieldRef(f.item.id, f.item.fields.last.id);
          final request = f.service.agent.request(session, '读取简历', [ref]);
          f.owner.approve(request.id, [ref]);
          await f.owner.retryAuditStorage();
          await f.fetch(session, request.id, 'held-copy');
          now = now.add(const Duration(hours: 9));
          f.driver.blocked = true;
          await f.owner.reconcileInformationFileDeliveries();
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Scaffold(
                body: SettingsPage(
                  owner: f.owner,
                  files: const NativeBackupFilePicker(),
                  initialSection: SettingsSection.application,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('有 1 份副本待回收'), findsOneWidget);
          await tester.tap(find.text('核查附件'));
          await waitForCheck(tester);
          expect(find.text('附件维护未完成'), findsOneWidget);
          expect(find.textContaining('保留登记'), findsWidgets);
          f.driver.blocked = false;
          await tester.tap(find.text('核查附件'));
          await waitForCheck(tester);
          expect(find.text('附件维护未完成'), findsNothing);
          expect(find.textContaining('有 1 份副本待回收'), findsNothing);
          expect(f.driver.bodies, isEmpty);
          expect(f.driver.sequence, 1);
          expect(find.textContaining('synthetic-private-path'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    },
  );
}
