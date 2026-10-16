import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/history.dart';
import 'package:info_desktop/ui.dart';
import 'package:info_desktop/settings.dart';
import 'package:info_desktop/backups.dart';

class _FailingPreferences extends MemoryInformationRepository {
  bool fail = true;
  @override
  Future<void> writeSetting(String key, int value) async {
    if (fail) throw StateError('synthetic storage failure');
    await super.writeSetting(key, value);
  }
}

void main() {
  testWidgets(
    'organization result opens its actual historical task across pages',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 1);
      final service = InformationService.fictional(clock: () => now);
      final chat = service.agent.openSession('Organization chat');
      String? target;
      for (var i = 0; i < 10; i++) {
        final task = await service.agent.requestOrganization(chat, '整理任务 $i', [
          'demo-server',
        ]);
        await service.owner.approveOrganization(task.id, ['demo-server']);
        await service.agent.submitOrganization(chat, task.id, []);
        target ??= task.id;
        now = now.add(const Duration(minutes: 1));
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: AuthorizationHistory(
              owner: service.owner,
              initialRecordId: target,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('整理任务 0'), findsNWidgets(2));
      expect(find.text('撤销授权'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
  testWidgets(
    'notification setting failure retains the intended choice for retry',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FailingPreferences();
      final service = InformationService(repository: repo);
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: SettingsPage(
              owner: service.owner,
              files: const NativeBackupFilePicker(),
              initialSection: SettingsSection.notifications,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-notifications-switch')),
      );
      await tester.pumpAndSettle();
      expect(service.owner.notificationsEnabled, isTrue);
      expect(
        tester
            .widget<Semantics>(
              find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.label == '访问申请通知',
              ),
            )
            .properties
            .toggled,
        isFalse,
      );
      repo.fail = false;
      await tester.tap(find.text('重试保存设置'));
      await tester.pumpAndSettle();
      expect(service.owner.notificationsEnabled, isFalse);
      await service.close();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'history search changes selection and keeps field values absent',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('History chat');
      for (var i = 0; i < 10; i++) {
        final r = service.agent.request(session, 'Deployment $i', [field]);
        service.owner.approve(r.id, [field]);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: AuthorizationHistory(owner: service.owner)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('history-search')),
        'Deployment 8',
      );
      await tester.pumpAndSettle();
      expect(find.text('Deployment 8'), findsNWidgets(3));
      expect(find.text('Deployment 9'), findsNothing);
      expect(find.textContaining('demo.example.invalid'), findsNothing);
      await service.close();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'settings theme updates root and request settings navigate to records',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-theme-green')));
      await tester.pumpAndSettle();
      expect(service.owner.colorTheme, DesktopColorTheme.green);
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('settings-theme-green'))),
        ).colorScheme.primary,
        const Color(0xff296a53),
      );
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请求设置'));
      await tester.pumpAndSettle();
      expect(find.text('等待审批时间'), findsOneWidget);
      expect(find.text('记录保留期限'), findsOneWidget);
      await service.close();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
