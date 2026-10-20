import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';

class KeyAccessPlatform extends NativeDesktopFixture {
  bool failTermination = false;
  int showCount = 0;
  int terminateCount = 0;
  @override
  Future<void> terminate() async {
    terminateCount++;
    if (failTermination) throw StateError('native termination failed');
    await super.terminate();
  }

  @override
  Future<void> showWindow() async {
    showCount++;
    await super.showWindow();
  }
}

void main() {
  group('owner Keychain recovery', () {
    test(
      'ordinary retries do not prompt; explicit recovery starts once',
      () async {
        final native = KeyAccessPlatform();
        var normalOpens = 0;
        var interactiveOpens = 0;
        var closed = 0;
        final entered = Completer<void>();
        final authorization = Completer<DesktopLibrary>();
        final bootstrap = DesktopBootstrap(
          port: 0,
          platform: native,
          openLibrary: () async {
            normalOpens++;
            throw const StorageFailure('key_unavailable');
          },
          openLibraryWithKeyAccess: () {
            interactiveOpens++;
            entered.complete();
            return authorization.future;
          },
        );
        await bootstrap.requestKeyAccess();
        expect(interactiveOpens, 0);
        await bootstrap.start();
        await bootstrap.start();
        expect(normalOpens, 2);
        expect(bootstrap.canRequestKeyAccess, isTrue);
        final recovering = bootstrap.requestKeyAccess();
        await entered.future;
        await bootstrap.start();
        await bootstrap.requestKeyAccess();
        expect(interactiveOpens, 1);
        expect(bootstrap.boundPort, isNull);
        expect(bootstrap.keyAccessPending, isTrue);
        authorization.complete(
          DesktopLibrary(
            service: InformationService(
              repository: MemoryInformationRepository(),
            ),
            close: () async {
              closed++;
            },
          ),
        );
        await recovering;
        expect(bootstrap.state, DesktopStartupState.ready);
        expect(bootstrap.keyAccessPending, isFalse);
        expect(bootstrap.canRequestKeyAccess, isFalse);
        expect(bootstrap.boundPort, isNotNull);
        await bootstrap.runtime!.quit();
        expect(closed, 1);
        bootstrap.runtime!.dispose();
        bootstrap.dispose();
      },
    );

    test(
      'denied recovery stays failed; ordinary retry remains noninteractive',
      () async {
        final native = KeyAccessPlatform();
        var interactiveOpens = 0;
        var normalOpens = 0;
        final bootstrap = DesktopBootstrap(
          platform: native,
          openLibrary: () async {
            normalOpens++;
            throw const StorageFailure('key_unavailable');
          },
          openLibraryWithKeyAccess: () async {
            interactiveOpens++;
            throw const StorageFailure('key_unavailable');
          },
        );
        await bootstrap.start();
        await bootstrap.requestKeyAccess();
        expect(bootstrap.state, DesktopStartupState.failed);
        expect(bootstrap.canRequestKeyAccess, isTrue);
        expect(bootstrap.library, isNull);
        expect(bootstrap.boundPort, isNull);
        await bootstrap.start();
        expect(normalOpens, 2);
        expect(interactiveOpens, 1);
        await native.events!(DesktopEvent.quit);
        expect(native.terminated, isTrue);
        bootstrap.dispose();
      },
    );

    for (final event in [DesktopEvent.quit, DesktopEvent.closeWindow]) {
      for (final lateSuccess in [true, false]) {
        test(
          '$event does not wait for authorization; late success=$lateSuccess cannot reopen',
          () async {
            final native = KeyAccessPlatform();
            final authorization = Completer<DesktopLibrary>();
            final entered = Completer<void>();
            var closed = 0;
            final bootstrap = DesktopBootstrap(
              port: 0,
              platform: native,
              openLibrary: () async =>
                  throw const StorageFailure('key_unavailable'),
              openLibraryWithKeyAccess: () {
                entered.complete();
                return authorization.future;
              },
            );
            await bootstrap.start();
            final recovering = bootstrap.requestKeyAccess();
            await entered.future;
            final shown = native.showCount;
            await native.events!(event).timeout(const Duration(seconds: 2));
            expect(native.terminated, isTrue);
            expect(authorization.isCompleted, isFalse);
            if (lateSuccess) {
              authorization.complete(
                DesktopLibrary(
                  service: InformationService(
                    repository: MemoryInformationRepository(),
                  ),
                  close: () async {
                    closed++;
                  },
                ),
              );
            } else {
              authorization.completeError(
                const StorageFailure('key_unavailable'),
              );
            }
            await recovering;
            expect(closed, lateSuccess ? 1 : 0);
            expect(bootstrap.state, DesktopStartupState.failed);
            expect(bootstrap.boundPort, isNull);
            expect(bootstrap.library, isNull);
            expect(bootstrap.runtime, isNull);
            expect(native.showCount, shown);
            bootstrap.dispose();
          },
        );
      }
    }

    testWidgets(
      'owner button, waiting state and failed quit remain actionable',
      (tester) async {
        final native = KeyAccessPlatform()..failTermination = true;
        final authorization = Completer<DesktopLibrary>();
        var opens = 0;
        final bootstrap = DesktopBootstrap(
          platform: native,
          openLibrary: () async =>
              throw const StorageFailure('key_unavailable'),
          openLibraryWithKeyAccess: () {
            opens++;
            return authorization.future;
          },
        );
        await tester.runAsync(bootstrap.start);
        await tester.pumpWidget(DesktopLauncher(bootstrap: bootstrap));
        expect(find.text('请求钥匙串访问'), findsOneWidget);
        Future<void>? recovery;
        await tester.runAsync(() async {
          recovery = bootstrap.requestKeyAccess();
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(opens, 1);
        expect(find.text('重试启动'), findsNothing);
        expect(find.text('请求钥匙串访问'), findsNothing);
        expect(find.textContaining('请在系统提示'), findsOneWidget);
        final quit = tester.widget<TextButton>(
          find.widgetWithText(TextButton, '退出应用'),
        );
        await tester.runAsync(() async {
          quit.onPressed!();
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(find.text('应用未能退出，请重试退出。'), findsOneWidget);
        native.failTermination = false;
        final retry = tester.widget<TextButton>(
          find.widgetWithText(TextButton, '重试退出'),
        );
        await tester.runAsync(() async {
          retry.onPressed!();
          await Future<void>.delayed(Duration.zero);
        });
        expect(native.terminated, isTrue);
        expect(native.terminateCount, 2);
        await tester.runAsync(() async {
          authorization.completeError(const StorageFailure('key_unavailable'));
          await recovery;
        });
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
        bootstrap.dispose();
      },
    );

    test(
      'unrelated storage failures and retained resources never offer recovery',
      () async {
        var recoveryCalls = 0;
        final bootstrap = DesktopBootstrap(
          platform: KeyAccessPlatform(),
          openLibrary: () async =>
              throw const StorageFailure('library_unavailable'),
          openLibraryWithKeyAccess: () async {
            recoveryCalls++;
            throw StateError('must not be called');
          },
        );
        await bootstrap.start();
        await bootstrap.requestKeyAccess();
        expect(bootstrap.canRequestKeyAccess, isFalse);
        bootstrap.systemKeyUnavailable = true;
        bootstrap.cleanupPending = true;
        await bootstrap.requestKeyAccess();
        expect(recoveryCalls, 0);
        bootstrap.dispose();
      },
    );
  }, skip: !Platform.isMacOS);
}
