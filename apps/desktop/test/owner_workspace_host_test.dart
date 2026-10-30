import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/runtime_workspace_desktop.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  test(
    'initial navigation uses the most recent runtime event exactly once',
    () async {
      for (final event in [
        DesktopEvent.openSettings,
        DesktopEvent.searchApprovals,
      ]) {
        final native = NativeDesktopFixture();
        final service = InformationService(
          repository: MemoryInformationRepository([]),
        );
        final runtime = DesktopRuntime(
          service: service,
          platform: native,
          closeServer: () async {},
          closeRepository: () async {},
        );
        await runtime.start();
        await runtime.handleEvent(DesktopEvent.openApprovals);
        await runtime.handleEvent(event);
        final desktop = RuntimeWorkspaceDesktop(runtime);
        final pages = <WorkspacePage>[];
        desktop.onNavigate = pages.add;
        expect(pages, [
          event == DesktopEvent.openSettings
              ? WorkspacePage.settings
              : WorkspacePage.library,
        ]);
        await runtime.handleEvent(DesktopEvent.availabilityChanged);
        expect(pages, hasLength(1));
        await desktop.setNavigationEnabled(false);
        await runtime.handleEvent(DesktopEvent.openApprovals);
        await desktop.setNavigationEnabled(true);
        expect(pages, hasLength(1));
        await runtime.handleEvent(DesktopEvent.openApprovals);
        expect(pages.last, WorkspacePage.approvals);
        desktop.dispose();
        await runtime.quit();
        runtime.dispose();
      }
    },
  );

  test(
    'native navigation respects editor gate and quit uses existing runtime',
    () async {
      final native = NativeDesktopFixture();
      final service = InformationService(
        repository: MemoryInformationRepository([]),
      );
      var serverClosed = 0, repositoryClosed = 0;
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {
          serverClosed++;
        },
        closeRepository: () async {
          repositoryClosed++;
        },
      );
      await runtime.start();
      final desktop = RuntimeWorkspaceDesktop(runtime);
      final pages = <WorkspacePage>[];
      desktop.onNavigate = pages.add;
      await desktop.setNavigationEnabled(false);
      await runtime.handleEvent(DesktopEvent.openSettings);
      expect(pages, isEmpty);
      await desktop.setNavigationEnabled(true);
      expect(pages, isEmpty, reason: 'a blocked menu action is not deferred');
      await runtime.handleEvent(DesktopEvent.openSettings);
      expect(pages, [WorkspacePage.settings]);
      await runtime.handleEvent(DesktopEvent.searchApprovals);
      expect(pages.last, WorkspacePage.library);
      native.availability = const DesktopAvailability(
        tray: true,
        notifications: NotificationAvailability.enabled,
        scrollbarStyle: DesktopScrollbarStyle.overlay,
      );
      await runtime.handleEvent(DesktopEvent.availabilityChanged);
      expect(desktop.scrollbarStyle.value, DesktopScrollbarStyle.overlay);
      await runtime.handleEvent(DesktopEvent.closeWindow);
      expect(native.hidden, isTrue);
      expect(service.owner.serviceAvailable, isTrue);
      await desktop.quit();
      expect(native.terminated, isTrue);
      expect(serverClosed, 1);
      expect(repositoryClosed, 1);
      expect(service.owner.serviceAvailable, isFalse);
      desktop.dispose();
      runtime.dispose();
    },
  );

  testWidgets(
    'formal launcher uses original owner, replaces restored projections and unmounts before shutdown',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final repository = MemoryInformationRepository([]);
      final native = NativeDesktopFixture();
      var opens = 0, closes = 0;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: native,
        openLibrary: () async {
          opens++;
          return DesktopLibrary(
            service: InformationService(repository: repository),
            close: () async {
              closes++;
            },
          );
        },
      );
      await t.runAsync(bootstrap.start);
      expect(bootstrap.state, DesktopStartupState.ready);
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
      }

      await t.pumpWidget(
        DesktopLauncher(bootstrap: bootstrap, useWorkspace: true),
      );
      await settle();
      expect(find.byType(InformationApp), findsNothing);
      final source =
          t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
              as OwnerWorkspaceSource;
      expect(identical(source.owner, bootstrap.library!.service.owner), isTrue);
      expect(repository.items, isEmpty);
      await t.runAsync(
        () => bootstrap.library!.service.owner.restoreLibrary(() async {}),
      );
      await settle();
      final next =
          t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
              as OwnerWorkspaceSource;
      expect(next, isNot(same(source)));
      expect(source.isCurrentLibrary, isFalse);
      expect(next.isCurrentLibrary, isTrue);
      expect(opens, 1);
      await t.runAsync(bootstrap.runtime!.quit);
      await settle();
      expect(find.byType(WorkspaceApp), findsNothing);
      expect(closes, 1);
      expect(native.terminated, isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle();
      bootstrap.runtime!.dispose();
      bootstrap.dispose();
    },
  );
}
