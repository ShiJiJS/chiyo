import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_desktop.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';

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
