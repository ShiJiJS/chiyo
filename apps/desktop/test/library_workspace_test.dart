import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/ui.dart';

void main() {
  testWidgets(
    'a rejected library query shows failure and never presents stale detail as a match',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: InformationLibrary(owner: service.owner),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'x' * 2001,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('信息库查询失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('information-demo-server')),
        findsNothing,
      );
      expect(find.text('请选择一条信息'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('library-search')), '');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('information-demo-server')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'library keeps three columns and clears detail on an unmatched query',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: InformationLibrary(owner: service.owner),
        ),
      );
      expect(find.byKey(const ValueKey('library-directory')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-detail')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'no match',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的信息'), findsOneWidget);
      expect(find.text('请选择一条信息'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('information-demo-server')),
        findsNothing,
      );
      await tester.tap(find.text('查看全部'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('information-demo-server')),
        findsOneWidget,
      );
    },
  );
}
