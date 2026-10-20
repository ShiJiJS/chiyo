import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/ui.dart';

void main() {
  testWidgets('many tags stay reachable at normal and large text sizes', (
    tester,
  ) async {
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
    for (var i = 0; i < 50; i++) {
      await service.owner.createTag('资料分类标签 $i');
    }
    for (var i = 0; i < 124; i++) {
      await service.owner.createInformation('资料 $i', '', [
        const FieldInput('字段', '', 'synthetic-value'),
      ]);
    }
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          theme: informationTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: InformationLibrary(owner: service.owner),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final last = find.byKey(
        ValueKey('library-tag-${service.owner.tags.last.id}'),
      );
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的信息'), findsOneWidget);
      expect(find.text('请选择一条信息'), findsOneWidget);
      final all = find.text('全部信息').first;
      await tester.ensureVisible(all);
      await tester.pumpAndSettle();
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('information-demo-server')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
