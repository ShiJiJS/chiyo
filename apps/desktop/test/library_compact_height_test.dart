import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/recycle.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('library navigation remains reachable at 800x600 / $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final service = InformationService.fictional();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      for (var i = 0; i < 30; i++) {
        await service.owner.createDirectory('合成目录 $i');
      }
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final value = find.text(
        service.owner.information.first.fields.first.value,
      );
      await tester.ensureVisible(value);
      await tester.pumpAndSettle();
      expect(value.hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('修改历史 ↗'));
      await tester.pumpAndSettle();
      expect(find.text('修改历史 ↗').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('library-directory')),
      );
      await tester.pumpAndSettle();
      final last = find.byKey(
        ValueKey('directory-${service.owner.directories.last.id}'),
      );
      await tester.scrollUntilVisible(
        last,
        180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('library-directory')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('合成目录 29'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('new-directory')),
        -180,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('library-directory')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('new-directory')).hitTestable(),
        findsOneWidget,
      );
      final recycle = find.descendant(
        of: find.byKey(const ValueKey('library-directory')),
        matching: find.text('回收站'),
      );
      await tester.ensureVisible(recycle);
      await tester.pumpAndSettle();
      expect(recycle.hitTestable(), findsOneWidget);
      await tester.tap(recycle);
      await tester.pumpAndSettle();
      expect(find.byType(RecyclePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
