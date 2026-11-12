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

  testWidgets('local choice opens the existing empty workspace and settings', (
    tester,
  ) async {
    await viewport(tester);
    await tester.pumpWidget(const SetupPreviewApp());
    await tester.pumpAndSettle();
    expect(find.text('你的资料，放在哪里？'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tap(tester, 'setup-continue');
    expect(find.byKey(const ValueKey('workspace-nav-library')), findsOneWidget);
    expect(find.text('自托管服务'), findsNothing);
    await tap(tester, 'workspace-nav-settings');
    await tap(tester, 'settings-section-connection');
    expect(find.text('存储与同步'), findsWidgets);
    expect(find.text('使用本地模式'), findsOneWidget);
  });

  testWidgets('invalid connection keeps the draft and can return to local', (
    tester,
  ) async {
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
    draft.address.text = 'http://192.168.1.20';
    draft.token.text = 'preserved-test-value';
    await tap(tester, 'setup-continue');
    expect(find.text('请填写完整的 HTTPS 服务器地址。'), findsOneWidget);
    expect(draft.token.text, 'preserved-test-value');
    expect(completed, isFalse);
    await tap(tester, 'setup-back');
    await tap(tester, 'setup-mode-local');
    await tap(tester, 'setup-continue');
    expect(completed, isTrue);
    expect(draft.enabled, isFalse);
  });

  testWidgets('server initialization leads to import and a connection state', (
    tester,
  ) async {
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
    await tap(tester, 'setup-initialize');
    expect(find.text('初始化服务器'), findsOneWidget);
    await tap(tester, 'setup-continue');
    await tap(tester, 'setup-import-confirm');
    expect(draft.address.text, 'https://192.168.1.20:47126');
    expect(draft.hasCertificate, isTrue);
    expect(find.text('已导入服务器证书'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setup-continue')));
    await tester.pump();
    expect(find.text('正在连接…'), findsOneWidget);
    expect(completed, isFalse);
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(draft.enabled, isTrue);
  });

  testWidgets('Token replacement can be cancelled and never clears data', (
    tester,
  ) async {
    await viewport(tester);
    final draft = SetupPreviewDraft()..importConnection();
    draft.saved = SetupStorageMode.server;
    draft.verified = true;
    addTearDown(draft.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: zhiyuTheme(Brightness.light),
        home: Scaffold(
          body: SetupConfigurationPreview(
            draft: draft,
            embedded: true,
            onComplete: () {},
            onBack: () {},
          ),
        ),
      ),
    );
    await tap(tester, 'setup-continue');
    final original = draft.token.text;
    await tap(tester, 'setup-replace-token');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(draft.token.text, original);
    await tap(tester, 'setup-replace-token');
    await tap(tester, 'setup-replace-confirm');
    expect(draft.token.text, isNot(original));
    expect(draft.hasCertificate, isTrue);
    expect(draft.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('setup remains usable with 200% text in ${brightness.name}', (
      tester,
    ) async {
      await viewport(tester, scale: 2);
      final draft = SetupPreviewDraft();
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(brightness),
          home: Scaffold(
            body: SetupConfigurationPreview(
              draft: draft,
              embedded: true,
              onComplete: () {},
              onBack: () {},
            ),
          ),
        ),
      );
      await tap(tester, 'setup-mode-server');
      await tap(tester, 'setup-continue');
      await tap(tester, 'setup-import');
      await tap(tester, 'setup-import-confirm');
      await tap(tester, 'setup-back');
      expect(find.text('存储与同步'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
