// Native semantics diagnostic with the real application widgets and only
// synthetic in-memory data. No OS input, CLI, SQLCipher or external UI client.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import '../test/support/focused_fill_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native focused-fill modal semantics diagnostic', (tester) async {
    void trace(String phase) {
      final root = tester
          .binding
          .renderViews
          .first
          .owner!
          .semanticsOwner
          ?.rootSemanticsNode;
      final children = <int>[];
      root?.visitChildren((child) {
        children.add(child.id);
        return true;
      });
      // IDs/counts only: never dump labels, values or a complete widget tree.
      debugPrint(
        jsonEncode({
          'phase': phase,
          'semantics': tester.binding.semanticsEnabled,
          'handles': tester.binding.debugOutstandingSemanticsHandles,
          'rootId': root?.id,
          'children': children,
        }),
      );
    }

    trace('before_fixture');
    final f = await focusedFillFixture();
    try {
      const delay = int.fromEnvironment('ACCESSIBILITY_PROBE_DELAY_MS');
      if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
      trace('before_mount');
      await tester.pumpWidget(InformationApp(service: f.service, port: 0));
      await tester.pumpAndSettle();
      trace('mounted');
      await tester.ensureVisible(
        find.byKey(const ValueKey('focused-fill-approve')),
      );
      await tester.tap(find.byKey(const ValueKey('focused-fill-approve')));
      await tester.pumpAndSettle();
      trace('confirmation_open');
      expect(
        find.byKey(const ValueKey('fill-confirm-decision')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('fill-confirm-decision')));
      await tester.pumpAndSettle();
      trace('approved');
      expect(f.owner.credentialUseRequests.single.credentialApproved, isTrue);
      expect(f.driver.sends, 0);
      expect(f.owner.focusedFillOperations, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await f.service.close();
    }
  });
}
