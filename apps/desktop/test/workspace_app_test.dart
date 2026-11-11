import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_desktop.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'package:info_desktop/workspace/workspace_sync.dart';

class _Sync extends ChangeNotifier implements WorkspaceSync {
  @override
  bool enabled = false;
  @override
  bool busy = false;
  @override
  bool needsReview = false;
  @override
  Object? failure;
  @override
  DateTime? updatedAt;
  int calls = 0;
  @override
  Future<void> synchronize() async {
    calls++;
  }

  void refresh() => notifyListeners();
}

class _Source extends SampleWorkspaceSource {
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _Desktop implements WorkspaceDesktop {
  @override
  void Function(WorkspacePage)? onNavigate;
  @override
  final ValueNotifier<DesktopScrollbarStyle> scrollbarStyle = ValueNotifier(
    DesktopScrollbarStyle.overlay,
  );
  @override
  Future<void> setNavigationEnabled(bool enabled) async {}
  @override
  Future<void> quit() async {}
}

void main() {
  testWidgets(
    'the shared toolbar reflects local sync without replacing the current library page',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final source = _Source(), sync = _Sync();
      addTearDown(source.dispose);
      addTearDown(sync.dispose);
      await t.pumpWidget(
        WorkspaceApp(source: source, windowTitle: '合成本地资料库', sync: sync),
      );
      await t.pumpAndSettle();
      final controller = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      const key = ValueKey('workspace-sync');
      expect(find.byKey(key), findsNothing);
      sync.enabled = true;
      sync.refresh();
      await t.pump();
      await t.tap(find.byKey(key));
      expect(sync.calls, 1);
      sync.busy = true;
      sync.refresh();
      await t.pump();
      expect(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(t.widget<TextButton>(find.byKey(key)).onPressed, isNull);
      sync.busy = false;
      sync.needsReview = true;
      sync.refresh();
      await t.pump();
      expect(find.text('同步 · 需处理冲突'), findsOneWidget);
      sync.failure = StateError('synthetic connection unavailable');
      sync.refresh();
      await t.pump();
      expect(find.text('同步失败，重试'), findsOneWidget);
      expect(
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller,
        same(controller),
      );
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source replacement releases old projections without owning services',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final first = _Source(), second = _Source(), desktop = _Desktop();
      addTearDown(() {
        first.dispose();
        second.dispose();
        desktop.scrollbarStyle.dispose();
      });
      Future<void> show(_Source source) async {
        await t.pumpWidget(
          WorkspaceApp(source: source, windowTitle: '合成服务', desktop: desktop),
        );
        await t.pumpAndSettle();
      }

      await show(first);
      final previous = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      expect(previous.source, same(first));
      expect(previous.query.directoryId, isNull);
      expect(previous.initialSelection, isNull);
      // Refreshing the same service retains page state/controllers.
      await show(first);
      expect(
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller,
        same(previous),
      );
      await show(second);
      final current = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      expect(current.source, same(second));
      expect(current, isNot(same(previous)));
      expect(first.disposed, isFalse);
      expect(second.disposed, isFalse);
      // Disposal of the previous view must not clear the new native callback.
      expect(desktop.onNavigate, isNotNull);
      desktop.onNavigate!(WorkspacePage.approvals);
      await t.pumpAndSettle();
      expect(
        t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller.location.page,
        WorkspacePage.approvals,
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      expect(desktop.onNavigate, isNull);
      expect(first.disposed || second.disposed, isFalse);
      expect(t.takeException(), isNull);
    },
  );
}
