import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/onboarding/setup_configuration_preview.dart';
import 'package:info_desktop/setup_preview_main.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  Future<void> viewport(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> fill(WidgetTester tester, String key, String text) async {
    final finder = find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(finder);
    await tester.enterText(finder, text);
    await tester.pump();
  }

  Future<void> wizard(WidgetTester tester, SetupPreviewDraft draft) async {
    await tester.pumpWidget(
      SetupConfigurationPreview(draft: draft, onComplete: () {}),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'setup-mode-server');
    await tap(tester, 'setup-continue');
  }

  Future<void> settings(
    WidgetTester tester,
    SetupPreviewDraft draft,
    Brightness brightness,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: zhiyuTheme(brightness),
        home: Scaffold(
          body: StorageSettingsPreview(draft: draft, onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'local setup enters the empty workspace; settings have no wizard',
    (tester) async {
      await viewport(tester);
      await tester.pumpWidget(const SetupPreviewApp());
      await tester.pumpAndSettle();
      await tap(tester, 'setup-continue');
      expect(
        find.byKey(const ValueKey('workspace-nav-library')),
        findsOneWidget,
      );
      await tap(tester, 'workspace-nav-settings');
      await tap(tester, 'settings-section-connection');
      expect(find.byType(StorageSettingsPreview), findsOneWidget);
      expect(find.byType(SetupConfigurationPreview), findsNothing);
      expect(find.text('首次配置'), findsNothing);
      expect(find.text('上一步'), findsNothing);
      expect(find.text('继续'), findsNothing);
      expect(find.text('资料保存在这台电脑'), findsOneWidget);
    },
  );

  testWidgets(
    'new server requires only IP, port and a matching initial password',
    (tester) async {
      await viewport(tester);
      final draft = SetupPreviewDraft();
      addTearDown(draft.dispose);
      var completed = false;
      await tester.pumpWidget(
        SetupConfigurationPreview(
          draft: draft,
          onComplete: () => completed = true,
        ),
      );
      await tap(tester, 'setup-mode-server');
      await tap(tester, 'setup-continue');
      await tap(tester, 'setup-continue');
      expect(find.byKey(const ValueKey('setup-error')), findsOneWidget);
      draft.host.text = '192.168.1.20';
      draft.port.text = '47126';
      await tap(tester, 'setup-continue');
      expect(find.text('设置管理密码'), findsOneWidget);
      expect(find.text('服务器证书已自动保存。'), findsOneWidget);
      expect(find.textContaining('Token'), findsNothing);
      expect(find.textContaining('导入'), findsNothing);
      await fill(tester, 'setup-password', 'synthetic-password');
      await fill(tester, 'setup-password-confirm', 'mismatch');
      await tap(tester, 'setup-continue');
      expect(find.text('两次输入的密码不一致，请重新确认。'), findsOneWidget);
      expect(completed, isFalse);
      await fill(tester, 'setup-password-confirm', 'synthetic-password');
      await tester.tap(find.byKey(const ValueKey('setup-continue')));
      await tester.pump();
      expect(find.text('正在完成配置…'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(draft.enabled, isTrue);
      expect(draft.certificateRemembered, isTrue);
      expect(draft.passwordMatches('synthetic-password'), isTrue);
    },
  );

  testWidgets(
    'initialized server asks for its existing password, not a reset',
    (tester) async {
      await viewport(tester);
      final draft = SetupPreviewDraft()..host.text = '192.168.1.20';
      draft.saveServer('existing-password');
      addTearDown(draft.dispose);
      await wizard(tester, draft);
      await tap(tester, 'setup-continue');
      expect(find.text('输入管理密码'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('setup-password-confirm')),
        findsNothing,
      );
      await fill(tester, 'setup-password', 'wrong-password');
      await tap(tester, 'setup-continue');
      expect(find.text('管理密码不正确，请重新输入。'), findsOneWidget);
      expect(draft.passwordMatches('existing-password'), isTrue);
    },
  );

  testWidgets('back navigation retains address and can choose local instead', (
    tester,
  ) async {
    await viewport(tester);
    final draft = SetupPreviewDraft()..host.text = '192.168.1.20';
    addTearDown(draft.dispose);
    await wizard(tester, draft);
    await tap(tester, 'setup-continue');
    await tap(tester, 'setup-back');
    expect(draft.host.text, '192.168.1.20');
    await tap(tester, 'setup-back');
    await tap(tester, 'setup-mode-local');
    await tap(tester, 'setup-continue');
    expect(draft.enabled, isFalse);
  });

  testWidgets(
    'daily password change checks current password and supports cancel',
    (tester) async {
      await viewport(tester);
      final draft = SetupPreviewDraft()..host.text = '192.168.1.20';
      draft.saveServer('existing-password');
      addTearDown(draft.dispose);
      await settings(tester, draft, Brightness.light);
      expect(find.text('首次配置'), findsNothing);
      expect(find.text('继续'), findsNothing);
      expect(find.textContaining('Token'), findsNothing);
      await tap(tester, 'settings-change-password');
      await fill(tester, 'settings-current-password', 'wrong-password');
      await fill(tester, 'settings-new-password', 'replacement-password');
      await fill(tester, 'settings-repeat-password', 'replacement-password');
      await tap(tester, 'settings-save-password');
      expect(find.text('当前密码不正确。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(draft.passwordMatches('existing-password'), isTrue);
      await tap(tester, 'settings-change-password');
      await fill(tester, 'settings-current-password', 'existing-password');
      await fill(tester, 'settings-new-password', 'replacement-password');
      await fill(tester, 'settings-repeat-password', 'replacement-password');
      await tap(tester, 'settings-save-password');
      expect(draft.passwordMatches('replacement-password'), isTrue);
      expect(draft.certificateRemembered, isTrue);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('daily settings stay usable at 200% in ${brightness.name}', (
      tester,
    ) async {
      await viewport(tester, scale: 2);
      final draft = SetupPreviewDraft()..host.text = '192.168.1.20';
      draft.saveServer('existing-password');
      addTearDown(draft.dispose);
      await settings(tester, draft, brightness);
      await tap(tester, 'settings-save-connection');
      expect(find.text('上一步'), findsNothing);
      await tap(tester, 'settings-change-password');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
