import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart' as app;
import 'package:integration_test/integration_test.dart';

import 'support/isolated_desktop.dart';

/// Opt-in only: an operator must click one genuine Windows Shell balloon.
/// No channel mocking, callback injection, permission changes or default profile.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('D1_MANUAL_NOTIFICATION');
  testWidgets(
    'manual Windows balloon opens the exact synthetic request across pages',
    (tester) async {
      expect(Platform.isWindows, isTrue, reason: 'Windows-only manual probe.');
      final platform = NativeDesktopPlatform();
      final fixture = await IsolatedDesktopFixture.start(
        platform: platform,
        prepareLibrary: (service) async {
          final item = service.owner.information.single;
          for (var i = 0; i < 25; i++) {
            final session = service.agent.openSession('Notification probe $i');
            service.agent.request(
              session,
              'Synthetic notification purpose $i',
              [FieldRef(item.id, item.fields.first.id)],
            );
          }
        },
      );
      addTearDown(() async {
        try {
          await platform.showWindow();
          await tester.pumpWidget(const SizedBox());
        } finally {
          await fixture.close();
        }
      });
      final runtime = fixture.bootstrap.runtime!;
      expect(
        runtime.availability.tray,
        isTrue,
        reason: 'No native tray entry; real notification not verified.',
      );
      expect(
        runtime.availability.notifications,
        NotificationAvailability.enabled,
        reason: 'OS notifications unavailable; real click not verified.',
      );

      // Choose from the actual stable ordering, rather than assume clock/ID
      // order. The target is outside the first eight-row inbox page.
      final target = fixture.service.owner.queryInbox(limit: 100).entries.last;
      final targetPage = fixture.service.owner.queryInbox(
        limit: 8,
        focusRequestId: target.id,
      );
      expect(targetPage.offset, greaterThan(0));
      await tester.pumpWidget(
        app.InformationApp(
          service: fixture.service,
          port: fixture.port,
          runtime: runtime,
          backups: fixture.bootstrap.library!.backups,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('request-${target.id}')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('inbox-search')),
        'no-such-synthetic-request',
      );
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      final revision = runtime.openApprovalsRevision;
      expect(runtime.openRequestId, isNull);

      // Hide only this isolated runner. A successful real click must restore it
      // through the native callback, switch tabs, clear search and select ID.
      expect(await platform.hideWindow(), isTrue);
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      debugPrint('D1_NOTIFICATION_DISPATCH requestId=${target.id}');
      final delivered = await tester.runAsync(
        () => platform
            .notifyNewRequest(target.id)
            .timeout(
              deadline.difference(DateTime.now()),
              onTimeout: () => false,
            ),
      );
      expect(
        delivered,
        isTrue,
        reason: 'Shell rejected/timed out; real balloon click not verified.',
      );
      debugPrint(
        'D1_NOTIFICATION_READY requestId=${target.id} '
        'remainingSeconds=${deadline.difference(DateTime.now()).inSeconds}',
      );
      while (runtime.openRequestId != target.id &&
          DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }
      expect(
        runtime.openRequestId,
        target.id,
        reason:
            'No genuine target balloon click within 60 seconds; '
            'OS may have suppressed it. Manual acceptance is incomplete.',
      );
      expect(platform.openedRequestId, target.id);
      expect(runtime.openApprovalsRevision, greaterThan(revision));
      await tester.pumpAndSettle();
      expect(find.byKey(PageStorageKey('detail-${target.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('request-${target.id}')), findsOneWidget);
      expect(find.text(target.purpose), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('inbox-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      debugPrint('D1_NOTIFICATION_VERIFIED requestId=${target.id}');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
