import 'package:flutter_test/flutter_test.dart';

/// Only for a live test that lets the OS request accessibility after it starts.
/// Keep the framework's leak verifier: first reject any extra handle beyond the
/// one created by the platform callback, then release that newly owned handle
/// after the application's widgets have been unmounted. Production is untouched.
class NativeSemanticsLifetime {
  NativeSemanticsLifetime(this.tester)
    : _handlesBefore = tester.binding.debugOutstandingSemanticsHandles,
      _platformBefore = tester.platformDispatcher.semanticsEnabled;

  final WidgetTester tester;
  final int _handlesBefore;
  final bool _platformBefore;

  Map<String, Object> finishAfterUnmount() {
    final platformNow = tester.platformDispatcher.semanticsEnabled;
    final newlyRequested = !_platformBefore && platformNow;
    final expected =
        _handlesBefore + (platformNow ? 1 : 0) - (_platformBefore ? 1 : 0);
    final observed = tester.binding.debugOutstandingSemanticsHandles;
    expect(
      observed,
      expected,
      reason: 'Unexpected native test semantics handle',
    );
    if (newlyRequested) {
      tester.platformDispatcher.semanticsEnabledTestValue = false;
      expect(tester.binding.debugOutstandingSemanticsHandles, _handlesBefore);
      addTearDown(tester.platformDispatcher.clearSemanticsEnabledTestValue);
    }
    return {
      'handlesBefore': _handlesBefore,
      'handlesAfterBody': observed,
      'newPlatformHandleReleasedAfterUnmount': newlyRequested,
    };
  }
}
