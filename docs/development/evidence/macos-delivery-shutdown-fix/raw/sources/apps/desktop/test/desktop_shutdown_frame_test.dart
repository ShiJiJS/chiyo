import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';

class _ClosableRepository extends MemoryInformationRepository {
  bool closed = false;
  @override
  int? readSetting(String key) {
    if (closed) throw StateError('library_closed');
    return super.readSetting(key);
  }
}

class _Termination extends NativeDesktopFixture {
  bool fail = false;
  int attempts = 0;
  @override
  Future<void> terminate() async {
    attempts++;
    if (fail) throw StateError('native termination unavailable');
    await super.terminate();
  }
}

void main() {
  test('native termination can retry after data closed', () async {
    final repository = _ClosableRepository();
    final native = _Termination()..fail = true;
    final bootstrap = DesktopBootstrap(
      port: 0,
      platform: native,
      openLibrary: () async => DesktopLibrary(
        service: InformationService(repository: repository),
        close: () async {
          repository.closed = true;
        },
      ),
    );
    await bootstrap.start();
    await bootstrap.runtime!.quit();
    expect(bootstrap.runtime!.shutdownFailed, isTrue);
    expect(repository.closed, isTrue);
    native.fail = false;
    await bootstrap.runtime!.quit().timeout(const Duration(seconds: 5));
    expect(native.attempts, 2);
    expect(native.terminated, isTrue);
    bootstrap.runtime!.dispose();
    bootstrap.dispose();
  });
  for (final mounted in [false, true]) {
    testWidgets(
      'quit with app frame mounted=$mounted never reads closed library',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = _ClosableRepository();
        final native = _Termination();
        final bootstrap = DesktopBootstrap(
          port: 0,
          platform: native,
          openLibrary: () async => DesktopLibrary(
            service: InformationService(repository: repository),
            close: () async {
              repository.closed = true;
            },
          ),
        );
        await tester.runAsync(bootstrap.start);
        if (mounted) {
          await tester.pumpWidget(DesktopLauncher(bootstrap: bootstrap));
        }
        await tester.runAsync(bootstrap.runtime!.quit);
        if (mounted) {
          await tester.pump();
        } else {
          await tester.pumpWidget(DesktopLauncher(bootstrap: bootstrap));
        }
        expect(tester.takeException(), isNull);
        expect(repository.closed, isTrue);
        expect(native.terminated, isTrue);
        expect(find.byType(InformationApp), findsNothing);
        await tester.pumpWidget(const SizedBox());
        bootstrap.runtime!.dispose();
        bootstrap.dispose();
      },
    );
  }
  testWidgets(
    'failed native termination retries without reopening closed library',
    (tester) async {
      final repository = _ClosableRepository();
      final native = _Termination()..fail = true;
      var closes = 0;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: native,
        openLibrary: () async => DesktopLibrary(
          service: InformationService(repository: repository),
          close: () async {
            closes++;
            repository.closed = true;
          },
        ),
      );
      await tester.runAsync(bootstrap.start);
      await tester.runAsync(bootstrap.runtime!.quit);
      await tester.pumpWidget(DesktopLauncher(bootstrap: bootstrap));
      expect(tester.takeException(), isNull);
      expect(find.byType(InformationApp), findsNothing);
      expect(find.text('重试退出'), findsOneWidget);
      await tester.pumpAndSettle();
      native.fail = false;
      final retry = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '重试退出'),
      );
      await tester.runAsync(() async {
        retry.onPressed!();
        expect(bootstrap.runtime!.shutdownFailed, isFalse);
        // Await the in-flight, deduplicated quit in the real async zone.
        await bootstrap.runtime!.quit().timeout(const Duration(seconds: 5));
        expect(native.attempts, 2);
        expect(native.terminated, isTrue);
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(native.terminated, isTrue);
      expect(closes, 1);
      await tester.pumpWidget(const SizedBox());
      bootstrap.runtime!.dispose();
      bootstrap.dispose();
    },
  );
}
