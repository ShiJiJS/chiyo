import 'support/workspace_fixtures.dart';
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
import 'package:info_desktop/desktop_scroll.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<void> nativeCommand(String method, [Object? arguments]) async {
    final done = Completer<ByteData?>();
    await messenger.handlePlatformMessage(
      MacPreviewDesktop.channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      done.complete,
    );
    final response = await done.future;
    if (response != null) codec.decodeEnvelope(response);
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
          'scrollbarStyle': 'legacy',
          'scrollbarRevision': 0,
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
    'a newer appearance event wins over a delayed initialize snapshot',
    () async {
      final reply = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(
        MacPreviewDesktop.channel,
        (_) => reply.future,
      );
      final desktop = MacPreviewDesktop();
      addTearDown(desktop.dispose);
      final start = desktop.initialize();
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'overlay',
        'revision': 1,
      });
      reply.complete({
        'isolated': true,
        'productionServices': false,
        'savedDirectories': false,
        'title': MacPreviewDesktop.windowTitle,
        'scrollbarStyle': 'legacy',
        'scrollbarRevision': 0,
      });
      await start;
      expect(desktop.scrollbarStyle.value, DesktopScrollbarStyle.overlay);
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'legacy',
        'revision': 0,
      });
      expect(desktop.scrollbarStyle.value, DesktopScrollbarStyle.overlay);
    },
  );

  test(
    'host appearance updates while navigation is gated and stops on disposal',
    () async {
      final calls = <MethodCall>[], desktop = await startDesktop(calls);
      final destinations = <WorkspacePage>[];
      desktop.onNavigate = destinations.add;
      var changes = 0;
      desktop.scrollbarStyle.addListener(() => changes++);
      expect(desktop.scrollbarStyle.value, DesktopScrollbarStyle.legacy);
      await desktop.setNavigationEnabled(false);
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'overlay',
        'revision': 1,
      });
      await nativeCommand('openSettings');
      expect(desktop.scrollbarStyle.value, DesktopScrollbarStyle.overlay);
      expect(changes, 1);
      expect(destinations, isEmpty);
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'overlay',
        'revision': 1,
      });
      expect(changes, 1);
      await expectLater(
        nativeCommand('scrollbarStyleChanged', {
          'style': 'invalid',
          'revision': 2,
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(desktop.scrollbarStyle.value, DesktopScrollbarStyle.overlay);
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'legacy',
        'revision': 2,
      });
      expect(changes, 2);
      desktop.dispose();
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'overlay',
        'revision': 1,
      });
      expect(changes, 2);
      await expectLater(desktop.initialize(), throwsStateError);
    },
  );

  testWidgets(
    'host scrollbar changes resize library without replacing an unsaved editor',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <MethodCall>[], desktop = await startDesktop(calls);
      await t.pumpWidget(
        PreviewWorkspace(inputsBuilder: fixtureInputs, desktop: desktop),
      );
      await t.pumpAndSettle();
      final title = find.byKey(const ValueKey('library-detail-title'));
      final width = t.getSize(title).width;
      final page = t.widget<LibraryPage>(find.byType(LibraryPage));
      final selected = page.controller.selection;
      await t.tap(find.text('编辑信息'));
      await t.pumpAndSettle();
      final name = find.byKey(const ValueKey('library-edit-name'));
      await t.enterText(name, 'Kept draft');
      final editor = t.widget<DesktopTextField>(name).controller!;
      final root = t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller;
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'overlay',
        'revision': 1,
      });
      await nativeCommand('openSettings');
      await t.pumpAndSettle();
      expect(root.location.page, WorkspacePage.library);
      expect(root.navigationLocked, true);
      expect(t.widget<DesktopTextField>(name).controller, same(editor));
      expect(editor.text, 'Kept draft');
      expect(page.controller.selection, selected);
      expect(t.getSize(title).width, width + 11);
      final dialogBehavior = ScrollConfiguration.of(t.element(name));
      expect((dialogBehavior as DesktopScrollBehavior).scrollbarGutter, 9);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.tap(find.text('放弃修改'));
      await t.pumpAndSettle();
      await nativeCommand('scrollbarStyleChanged', {
        'style': 'legacy',
        'revision': 2,
      });
      await t.pumpAndSettle();
      expect(t.getSize(title).width, width);
      expect(page.controller.selection, selected);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
  );

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
            'scrollbarStyle': 'legacy',
            'scrollbarRevision': 0,
          };
        }
        return null;
      });
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      WorkspacePage? current;
      await tester.pumpWidget(
        PreviewWorkspace(
          inputsBuilder: fixtureInputs,
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
      expect(find.byKey(const ValueKey('preview-guide')), findsNothing);
      await desktop.setNavigationEnabled(false);
      expect(commands.last.arguments, false);
      await desktop.setNavigationEnabled(true);
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
      await t.pumpWidget(
        PreviewWorkspace(inputsBuilder: fixtureInputs, desktop: desktop),
      );
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
      await t.pumpWidget(
        PreviewWorkspace(inputsBuilder: fixtureInputs, desktop: desktop),
      );
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
