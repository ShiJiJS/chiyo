import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_runtime.dart';

import 'support/desktop_platform_fixture.dart';

void main() {
  for (final navigationEnabled in [true, false]) {
    test(
      'close before online settings load respects the navigation gate: $navigationEnabled',
      () async {
        final platform = NativeDesktopFixture();
        var releases = 0;
        final runtime = OnlineDesktopRuntime(
          platform: platform,
          beforeExit: () async => releases++,
          onResume: () async {},
        );
        addTearDown(runtime.dispose);
        await runtime.start();
        await runtime.setNavigationEnabled(navigationEnabled);
        expect(runtime.preferences, isNull);

        await platform.events!(DesktopEvent.closeWindow);

        expect(platform.terminated, navigationEnabled);
        expect(runtime.closed, navigationEnabled);
        expect(releases, navigationEnabled ? 1 : 0);
        expect(platform.hidden, isFalse);
      },
    );
  }
}
