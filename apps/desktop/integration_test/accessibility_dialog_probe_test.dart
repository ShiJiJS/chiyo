// Diagnostic only: no information library, credentials, broker or CLI.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native accessibility simple modal diagnostic', (tester) async {
    const observe = bool.fromEnvironment('ACCESSIBILITY_LATE_OBSERVER');
    const evidence = String.fromEnvironment('ACCESSIBILITY_EVIDENCE');
    final label = ValueNotifier('Open');
    Future<void> record(String phase) async {
      final value = {
        'phase': phase,
        'frameworkSemantics': tester.binding.semanticsEnabled,
        'nativeSemantics': tester.binding.platformDispatcher.semanticsEnabled,
        'handles': tester.binding.debugOutstandingSemanticsHandles,
        'rootId': tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner
            ?.rootSemanticsNode
            ?.id,
      };
      debugPrint(jsonEncode(value));
      if (observe) {
        await File('$evidence/events.jsonl').writeAsString(
          '${jsonEncode(value)}\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    }

    if (observe) {
      expect(evidence, isNotEmpty);
      await Directory(evidence).create(recursive: true);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Synthetic confirmation'),
                  content: const Text(
                    'No library or credentials are involved.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: ValueListenableBuilder(
                valueListenable: label,
                builder: (_, text, _) => Text(text),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await record('mounted');
    if (observe) {
      await File(
        '$evidence/ready.json',
      ).writeAsString('{"ready":true}', flush: true);
      final limit = DateTime.now().add(const Duration(seconds: 60));
      while (!await File('$evidence/continue').exists() &&
          DateTime.now().isBefore(limit)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await File('$evidence/continue').exists(), isTrue);
      await record('observer_connected');
      expect(tester.binding.platformDispatcher.semanticsEnabled, isTrue);
      label.value = 'Open after update';
      await tester.pumpAndSettle();
      await record('incremental_update');
    }
    await tester.tap(find.text(label.value));
    await tester.pumpAndSettle();
    await record('modal_open');
    expect(find.text('Synthetic confirmation'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await record('modal_closed');
    expect(find.text('Synthetic confirmation'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    label.dispose();
  });
}
