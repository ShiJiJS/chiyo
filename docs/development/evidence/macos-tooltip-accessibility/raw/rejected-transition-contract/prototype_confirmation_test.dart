import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/prototype_dialog.dart';
import 'package:info_desktop/ui.dart';

void main() {
  for (final accepted in [false, true]) {
    testWidgets(
      'confirmation finishes leaving its overlay before ${accepted ? 'closing' : 'retaining'} its parent',
      (tester) async {
        final draft = TextEditingController(text: 'Original draft');
        final completed = <bool>[];
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (parentContext) => PrototypeDialog(
                        title: 'Parent editor',
                        body: TextField(
                          key: const ValueKey('draft'),
                          controller: draft,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              final answer = await prototypeConfirm(
                                parentContext,
                                title: 'Confirm action?',
                                message: 'Synthetic confirmation',
                                action: 'Confirm',
                              );
                              completed.add(answer);
                              if (answer && parentContext.mounted)
                                Navigator.pop(parentContext);
                            },
                            child: const Text('Finish parent'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Open parent'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open parent'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('draft')),
            'Keep synthetic draft',
          );
          await tester.tap(find.text('Finish parent'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(accepted ? 'Confirm' : '取消'));
          await tester.pump();
          // Resolving at pop start lets the caller remove the parent while
          // the confirmation still owns overlay/semantics nodes.
          expect(completed, isEmpty);
          await tester.pump(const Duration(milliseconds: 50));
          expect(completed, isEmpty);
          expect(find.text('Parent editor'), findsOneWidget);
          await tester.pumpAndSettle();
          expect(completed, [accepted]);
          expect(
            find.text('Parent editor'),
            accepted ? findsNothing : findsOneWidget,
          );
          expect(draft.text, 'Keep synthetic draft');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          draft.dispose();
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }
}
