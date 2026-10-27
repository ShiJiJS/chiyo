import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/desktop_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<void> nativeCommand(String method) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      MacPreviewDesktop.channel.name,
      codec.encodeMethodCall(MethodCall(method)),
      (_) => done.complete(),
    );
    await done.future;
  }

  Future<MacPreviewDesktop> startDesktop(List<MethodCall> calls) async {
    messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') {
        return {
          'isolated': true,
          'productionServices': false,
          'savedDirectories': false,
          'title': MacPreviewDesktop.windowTitle,
        };
      }
      return null;
    });
    final desktop = MacPreviewDesktop();
    await desktop.initialize();
    return desktop;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, null);
  });

  test(
    'preview fails closed when the native mode is missing or incomplete',
    () async {
      final desktop = MacPreviewDesktop();
      addTearDown(desktop.dispose);
      await expectLater(
        desktop.initialize(),
        throwsA(isA<MissingPluginException>()),
      );
      messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (_) async {
        return {
          'isolated': true,
          'productionServices': true,
          'savedDirectories': false,
        };
      });
      await expectLater(desktop.initialize(), throwsStateError);
    },
  );

  testWidgets(
    'Mac menu commands navigate the preview and modal gates navigation',
    (tester) async {
      final commands = <MethodCall>[];
      messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (
        call,
      ) async {
        commands.add(call);
        if (call.method == 'initialize') {
          return {
            'isolated': true,
            'productionServices': false,
            'savedDirectories': false,
            'title': MacPreviewDesktop.windowTitle,
          };
        }
        return null;
      });
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      WorkspacePage? current;
      await tester.pumpWidget(
        PreviewWorkspace(
          desktop: desktop,
          pageBuilder: (_, location) {
            current = location.page;
            return Text('destination:${location.page.name}');
          },
        ),
      );
      await tester.pumpAndSettle();
      await nativeCommand('openSettings');
      await tester.pumpAndSettle();
      expect(current, WorkspacePage.settings);
      await nativeCommand('searchApprovals');
      await tester.pumpAndSettle();
      expect(current, WorkspacePage.library);
      await tester.tap(find.byKey(const ValueKey('preview-guide')));
      await tester.pumpAndSettle();
      expect(commands.last.method, 'setNavigationEnabled');
      expect(commands.last.arguments, false);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(commands.last.arguments, true);
      await tester.pumpWidget(const SizedBox());
      await nativeCommand('openSettings');
      expect(current, WorkspacePage.library);
    },
  );
  test(
    'queued native commands are ignored while the local navigation gate is closed',
    () async {
      final calls = <MethodCall>[],
          desktop = await startDesktop(calls),
          destinations = <WorkspacePage>[];
      addTearDown(desktop.dispose);
      desktop.onNavigate = destinations.add;
      await desktop.setNavigationEnabled(false);
      await nativeCommand('openSettings');
      await nativeCommand('open');
      expect(destinations, isEmpty);
      await desktop.setNavigationEnabled(true);
      await nativeCommand('open');
      expect(destinations, [WorkspacePage.approvals]);
    },
  );

  testWidgets(
    'approval refresh cannot unlock an unsaved editor or an overlapping modal; native input preserves the draft',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <MethodCall>[], desktop = await startDesktop(calls);
      await t.pumpWidget(PreviewWorkspace(desktop: desktop));
      await t.pumpAndSettle();
      final page = t.widget<LibraryPage>(find.byType(LibraryPage)),
          source = page.controller.source as SampleWorkspaceSource;
      final root = t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller;
      await t.tap(find.text('编辑信息'));
      await t.pumpAndSettle();
      final name = find.byKey(const ValueKey('library-edit-name'));
      await t.enterText(name, '原生导航不能丢失的未保存修改');
      final modal = page.onModalChanged!;
      modal(true); // A second modal producer overlaps the editor.
      source.advanceApprovalClock(Duration.zero);
      await t.pumpAndSettle();
      expect(root.navigationLocked, true);
      expect(calls.last.arguments, false);
      await nativeCommand('openSettings');
      await t.pumpAndSettle();
      expect(root.location.page, WorkspacePage.library);
      expect(
        t.widget<DesktopTextField>(name).controller!.text,
        '原生导航不能丢失的未保存修改',
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.tap(find.text('放弃修改'));
      await t.pumpAndSettle();
      expect(root.navigationLocked, true);
      expect(calls.last.arguments, false);
      modal(false);
      await t.pumpAndSettle();
      expect(root.navigationLocked, false);
      expect(calls.last.arguments, true);
      await nativeCommand('openSettings');
      await t.pumpAndSettle();
      expect(root.location.page, WorkspacePage.settings);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
  );

  testWidgets(
    'a late modal close cannot release an unresolved approval decision',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <MethodCall>[], desktop = await startDesktop(calls);
      await t.pumpWidget(PreviewWorkspace(desktop: desktop));
      await t.pumpAndSettle();
      final page = t.widget<LibraryPage>(find.byType(LibraryPage)),
          source = page.controller.source as SampleWorkspaceSource;
      final lateClose = page.onModalChanged!,
          root = t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller;
      await t.tap(find.byKey(const ValueKey('workspace-nav-approvals')));
      await t.pumpAndSettle();
      source.loseNextApprovalReply = true;
      final approve = find.byKey(const ValueKey('approval-approve'));
      await t.ensureVisible(approve);
      await t.pumpAndSettle();
      await t.tap(approve);
      await t.pumpAndSettle();
      final approvals = t
          .widget<ApprovalsPage>(find.byType(ApprovalsPage))
          .controller;
      expect(approvals.uncertain, true);
      lateClose(false);
      await t.pumpAndSettle();
      expect(calls.last.arguments, false);
      await nativeCommand('openSettings');
      await t.pumpAndSettle();
      expect(root.location.page, WorkspacePage.approvals);
      final reconcile = find.byKey(const ValueKey('approval-reconcile'));
      await t.ensureVisible(reconcile);
      await t.pumpAndSettle();
      await t.tap(reconcile);
      await t.pumpAndSettle();
      expect(approvals.uncertain, false);
      expect(calls.last.arguments, true);
      await nativeCommand('openSettings');
      await t.pumpAndSettle();
      expect(root.location.page, WorkspacePage.settings);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
  );
}
