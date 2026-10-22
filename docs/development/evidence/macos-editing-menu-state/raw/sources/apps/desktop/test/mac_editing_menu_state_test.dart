import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/mac_text_editing.dart';

import 'mac_text_editing_test.dart' show nativeAction, nativeSelectAll;

void main() {
  testWidgets(
    'native menu state follows selection history read-only and obscured focus',
    (tester) async {
      final first = TextEditingController(text: 'Original');
      final secret = TextEditingController(text: 'Synthetic secret');
      addTearDown(first.dispose);
      addTearDown(secret.dispose);
      var readOnly = false;
      var hasStrings = true;
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': hasStrings};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => MacTextEditingActions(child: child!),
          home: Material(
            child: StatefulBuilder(
              builder: (_, setState) {
                rebuild = setState;
                return Column(
                  children: [
                    TextField(
                      key: const ValueKey('editor'),
                      controller: first,
                      readOnly: readOnly,
                    ),
                    TextField(
                      key: const ValueKey('secret'),
                      controller: secret,
                      obscureText: true,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      expect(await nativeAction('getEditingState'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('editor')));
      await tester.pump(const Duration(seconds: 1));
      expect(await nativeAction('getEditingState'), {
        'deleteSelection': false,
        'copy': false,
        'cut': false,
        'paste': true,
        'selectAll': true,
        'undo': false,
        'redo': false,
      });
      await nativeSelectAll();
      expect(await nativeAction('getEditingState'), {
        'deleteSelection': true,
        'copy': true,
        'cut': true,
        'paste': true,
        'selectAll': false,
        'undo': false,
        'redo': false,
      });
      expect(await nativeAction('deleteSelection'), true);
      await tester.pump(const Duration(seconds: 1));
      expect(first.text, isEmpty);
      await nativeAction('undo');
      await tester.pump();
      expect(first.text, 'Original');
      await tester.enterText(find.byKey(const ValueKey('editor')), 'Changed');
      await tester.pump(const Duration(seconds: 1));
      expect((await nativeAction('getEditingState') as Map)['undo'], true);
      await nativeAction('undo');
      await tester.pump();
      expect((await nativeAction('getEditingState') as Map)['redo'], true);
      rebuild(() => readOnly = true);
      await tester.pump();
      await nativeSelectAll();
      expect(await nativeAction('getEditingState'), {
        'deleteSelection': false,
        'copy': true,
        'cut': false,
        'paste': false,
        'selectAll': false,
        'undo': false,
        'redo': false,
      });
      expect(await nativeAction('deleteSelection'), false);
      expect(first.text, 'Original');
      await tester.tap(find.byKey(const ValueKey('secret')));
      await tester.pump(const Duration(seconds: 1));
      await nativeSelectAll();
      expect(await nativeAction('getEditingState'), {
        'deleteSelection': true,
        'copy': false,
        'cut': false,
        'paste': true,
        'selectAll': false,
        'undo': false,
        'redo': false,
      });
      hasStrings = false;
      expect((await nativeAction('getEditingState') as Map)['paste'], false);
      expect(calls, isNot(contains('Clipboard.getData')));
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('menu query discards a reply after focus changes', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.hasStrings' ? pending.future : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MacTextEditingActions(child: child!),
        home: Material(
          child: Column(
            children: [
              TextField(focusNode: first),
              TextField(focusNode: second),
            ],
          ),
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();
    final reply = nativeAction('getEditingState');
    await tester.pump();
    second.requestFocus();
    await tester.pump();
    pending.complete({'value': true});
    expect(await reply, isEmpty);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
