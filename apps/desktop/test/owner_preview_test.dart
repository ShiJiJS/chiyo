import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> tap(WidgetTester t, String value) async {
    await t.ensureVisible(key(value));
    await t.tap(key(value));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> start(
    WidgetTester t, {
    bool large = false,
    MacPreviewDesktop? desktop,
  }) async {
    t.view.physicalSize = large ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = large ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    // The same default composition as preview_main; no fixture input adapters.
    await t.pumpWidget(PreviewWorkspace(desktop: desktop));
    await t.pumpAndSettle();
  }

  SampleWorkspaceSource source(WidgetTester t) =>
      t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
          as SampleWorkspaceSource;

  for (final large in [false, true]) {
    testWidgets(
      'owner navigation and credential management have no scenario controls large=$large',
      (t) async {
        await start(t, large: large);
        if (large) {
          await tap(t, 'workspace-nav-settings');
          await tap(t, 'settings-theme-dark');
        }
        for (final page in WorkspacePage.values) {
          await tap(t, 'workspace-nav-${page.name}');
          expect(find.text('设计说明'), findsNothing);
          expect(find.text('重置预览资料'), findsNothing);
          expect(find.text('恢复预览运行'), findsNothing);
          expect(find.text('申请使用'), findsNothing);
        }
        await tap(t, 'workspace-nav-library');
        final m = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
        await m.openRelated(ssh);
        await t.pumpAndSettle();
        expect(key('credential-use'), findsNothing);
        for (final action in ['replace', 'toggle', 'history', 'refresh']) {
          expect(key('credential-$action'), findsOneWidget);
        }
        await tap(t, 'credential-toggle');
        await tap(t, 'credential-toggle-submit');
        expect((await m.source.credentials.read(ssh)).enabled, isFalse);
        expect(key('credential-use'), findsNothing);
      },
    );
  }

  testWidgets(
    'Agent submits a request, owner opens and approves it without fabricating execution',
    (t) async {
      await start(t);
      final s = source(t),
          m = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
      final detail = await s.credentials.read(ssh);
      final receipt = await s.credentials.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: workspaceOperationId(),
          ref: ssh,
          expectedRecordVersion: detail.recordVersion,
          expectedMaterialVersion: detail.materialVersion,
          useGeneration: detail.useGeneration,
          purpose: 'Agent检查服务器',
          sessionId: (await s.credentials.sessions()).first.id,
          receiverId: (await s.credentials.receivers(ssh)).first.id,
          minutes: 15,
        ),
      );
      await m.openRelated(ssh);
      await t.pumpAndSettle();
      expect(key('credential-use'), findsNothing);
      await tap(t, 'credential-open-request-${receipt.requestId}');
      final a = t.widget<ApprovalsPage>(find.byType(ApprovalsPage)).controller;
      expect(a.detail!.credential!.id, receipt.requestId);
      await tap(t, 'approval-approve');
      expect(a.detail!.request.state, WorkspaceApprovalState.approved);
      expect(a.detail!.executions, isEmpty);
      await tap(t, 'approval-revoke');
      expect(a.detail!.request.state, WorkspaceApprovalState.revoked);
      expect((await s.credentials.read(ssh)).enabled, isTrue);
    },
  );

  testWidgets(
    'unconnected material, plugin and backup inputs never offer preset test candidates',
    (t) async {
      await start(t);
      final m = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
      await m.openRelated(ssh);
      await t.pumpAndSettle();
      final original = await m.source.credentials.read(ssh);
      await tap(t, 'credential-replace');
      await tap(t, 'credential-edit-candidate');
      expect(find.text('凭据输入服务不可用，请稍后重试。'), findsOneWidget);
      expect(key('credential-candidate-ssh-file'), findsNothing);
      await t.tap(find.text('取消').last);
      await t.pumpAndSettle();
      expect(
        (await m.source.credentials.read(ssh)).materialVersion,
        original.materialVersion,
      );
      await tap(t, 'workspace-nav-settings');
      await tap(t, 'settings-section-plugins');
      await tap(t, 'plugin-install');
      expect(find.text('本机插件文件选择尚未接入。'), findsOneWidget);
      expect(find.text('字段格式错误.json'), findsNothing);
      await t.tap(find.text('取消').last);
      await t.pumpAndSettle();
      await tap(t, 'settings-section-backups');
      await tap(t, 'backup-open-key');
      await tap(t, 'backup-enable');
      await tap(t, 'backup-pick-keyOutput');
      expect(find.text('本机备份文件服务尚未接入，没有读取或写入文件。'), findsWidgets);
      expect(find.text('选择文件或保存位置'), findsNothing);
    },
  );

  testWidgets(
    'confirmed complete quit uses Cocoa quit without a preview resume page',
    (t) async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MacPreviewDesktop.channel, (call) async {
            methods.add(call.method);
            if (call.method == 'initialize') {
              return {
                'isolated': true,
                'productionServices': false,
                'savedDirectories': false,
                'title': MacPreviewDesktop.windowTitle,
                'scrollbarStyle': 'legacy',
                'scrollbarRevision': 0,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MacPreviewDesktop.channel, null),
      );
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      await start(t, desktop: desktop);
      await tap(t, 'workspace-nav-settings');
      await tap(t, 'settings-section-runtime');
      await tap(t, 'runtime-quit');
      await tap(t, 'runtime-quit-confirm');
      expect(methods.where((m) => m == 'quit'), hasLength(1));
      expect(key('preview-runtime-resume'), findsNothing);
      expect(find.text('恢复预览运行'), findsNothing);
    },
  );
}
