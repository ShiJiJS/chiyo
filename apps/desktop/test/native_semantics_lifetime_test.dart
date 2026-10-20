import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/native_semantics_lifetime.dart';

void main() {
  testWidgets('native platform handle is released only after unmount', (
    tester,
  ) async {
    final lifetime = NativeSemanticsLifetime(tester);
    final before = tester.binding.debugOutstandingSemanticsHandles;
    tester.platformDispatcher.semanticsEnabledTestValue = true;
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.debugOutstandingSemanticsHandles, before + 1);
    final facts = lifetime.finishAfterUnmount();
    expect(facts['newPlatformHandleReleasedAfterUnmount'], isTrue);
    expect(tester.binding.debugOutstandingSemanticsHandles, before);
  }, semanticsEnabled: false);

  testWidgets(
    'an extra application handle still fails native lifetime validation',
    (tester) async {
      final lifetime = NativeSemanticsLifetime(tester);
      tester.platformDispatcher.semanticsEnabledTestValue = true;
      final leaked = tester.ensureSemantics();
      await tester.pumpWidget(const SizedBox());
      expect(
        lifetime.finishAfterUnmount,
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains(
              'Unexpected native test semantics handle',
            ),
          ),
        ),
      );
      // Only this deliberate test leak is cleaned up; the failed validation
      // above must not have disposed it or ignored it.
      leaked.dispose();
      final facts = lifetime.finishAfterUnmount();
      expect(facts['newPlatformHandleReleasedAfterUnmount'], isTrue);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'a native request present before the case is left owned by the platform',
    (tester) async {
      tester.platformDispatcher.semanticsEnabledTestValue = true;
      final lifetime = NativeSemanticsLifetime(tester);
      final before = tester.binding.debugOutstandingSemanticsHandles;
      await tester.pumpWidget(const SizedBox());
      final facts = lifetime.finishAfterUnmount();
      expect(facts['newPlatformHandleReleasedAfterUnmount'], isFalse);
      expect(tester.binding.debugOutstandingSemanticsHandles, before);
      tester.platformDispatcher.clearSemanticsEnabledTestValue();
    },
    semanticsEnabled: false,
  );
}
