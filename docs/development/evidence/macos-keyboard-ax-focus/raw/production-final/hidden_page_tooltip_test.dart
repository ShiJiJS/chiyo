import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets(
    'a tooltip from a retained page disappears after semantic navigation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        await tester.pumpWidget(InformationApp(service: service, port: 0));
        await tester.pumpAndSettle();
        final previous = find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == '上一页请求',
        );
        expect(previous, findsOneWidget);
        final retainedTooltip = tester.state<TooltipState>(previous);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(previous));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('上一页请求'), findsOneWidget);
        // Accessibility navigation does not need to move the physical mouse.
        final nav = tester.getSemantics(find.byKey(const ValueKey('nav-1')));
        tester.semantics.performAction(
          find.semantics.byPredicate((n) => n.id == nav.id),
          SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expect(find.text('上一页请求'), findsNothing);
        expect(retainedTooltip.mounted, isTrue);
        // A delayed display callback must not resurrect a retained page's
        // tooltip after accessibility navigation has hidden that page.
        expect(retainedTooltip.ensureTooltipVisible(), isFalse);
        await tester.pumpAndSettle();
        expect(find.text('上一页请求'), findsNothing);
        expect(find.byKey(const ValueKey('library-search')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        semantics.dispose();
        final closing = service.close();
        await tester.pump();
        await closing;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
