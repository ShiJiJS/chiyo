import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'support/information_attachment_fixture.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'compact full app can review a file before partial approval at $scale',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        await tester.runAsync(() async {
          final f = await AttachmentUiFixture.create();
          try {
            final session = f.service.agent.openSession(
              'Mac 小窗口审批可达性独立复现 20261023',
            );
            final textRef = FieldRef(f.item.id, f.item.fields.first.id);
            final fileRef = FieldRef(f.item.id, f.item.fields.last.id);
            final request = f.service.agent.request(
              session,
              '仅合成资料复现窄窗口文件说明可达性，不修改原资料',
              [textRef, fileRef],
            );
            await tester.pumpWidget(
              InformationApp(service: f.service, port: 0),
            );
            await tester.pumpAndSettle();
            final body = find.byKey(PageStorageKey('detail-${request.id}'));
            final documentSemantics = tester.getSemantics(body);
            final lifetimeSemantics = tester.getSemantics(
              find.descendant(
                of: find.byKey(ValueKey('grant-lifetime-${request.id}')),
                matching: find.byType(EditableText),
              ),
            );
            expect(documentSemantics.flagsCollection.isTextField, isFalse);
            expect(lifetimeSemantics.id, isNot(documentSemantics.id));
            expect(lifetimeSemantics.flagsCollection.isTextField, isTrue);
            expect(lifetimeSemantics.label, contains('授权有效期'));
            expect(lifetimeSemantics.rect.width, lessThan(200));
            final scrollable = find.descendant(
              of: body,
              matching: find.byType(Scrollable),
            );
            expect(scrollable, findsOneWidget);
            final position = tester.state<ScrollableState>(scrollable).position;
            expect(position.maxScrollExtent, greaterThan(0));
            final rect = tester.getRect(body);
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: rect.center,
                scrollDelta: const Offset(0, 300),
              ),
            );
            await tester.pumpAndSettle();
            expect(position.pixels, greaterThan(0));
            final file = find.byKey(ValueKey('field-${fileRef.fieldId}'));
            await tester.scrollUntilVisible(file, 150, scrollable: scrollable);
            await tester.pumpAndSettle();
            expect(file.hitTestable(), findsOneWidget);
            expect(find.textContaining('fictional-resume.pdf'), findsOneWidget);
            final text = find.byKey(ValueKey('field-${textRef.fieldId}'));
            await tester.scrollUntilVisible(text, -150, scrollable: scrollable);
            await tester.pumpAndSettle();
            await tester.tap(text);
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const ValueKey('approve-selection')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('approve-selection')));
            await tester.pumpAndSettle();
            expect(f.service.agent.claim(session, request.id).fields, [
              fileRef,
            ]);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await f.close();
            semantics.dispose();
          }
        });
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }
}
