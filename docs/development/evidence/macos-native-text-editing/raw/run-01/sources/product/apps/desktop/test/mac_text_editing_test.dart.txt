import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/mac_text_editing.dart';

Future<Object?> nativeSelectAll() async {
  final result = Completer<ByteData?>();
  const codec = StandardMethodCodec();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'agent_info_manage/text_editing',
        codec.encodeMethodCall(const MethodCall('selectAll')),
        result.complete,
      );
  final reply = await result.future;
  return reply == null ? null : codec.decodeEnvelope(reply);
}

void main() {
  testWidgets('native Select All updates only the focused Flutter editor', (
    tester,
  ) async {
    final first = TextEditingController(text: 'Keep this field');
    final second = TextEditingController(text: 'Select this text');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MacTextEditingActions(child: child!),
        home: Material(
          child: Column(
            children: [
              TextField(controller: first),
              TextField(key: const ValueKey('active'), controller: second),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('active')));
    await tester.pump();
    expect(await nativeSelectAll(), true);
    await tester.pump();
    expect(
      second.selection,
      const TextSelection(baseOffset: 0, extentOffset: 16),
    );
    expect(second.text, 'Select this text');
    expect(first.text, 'Keep this field');
    expect(first.selection.isValid, false);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(second.text, isEmpty);
    expect(first.text, 'Keep this field');
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native Select All ignores non-editor focus', (tester) async {
    final controller = TextEditingController(text: 'Preserve input');
    final buttonFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(buttonFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MacTextEditingActions(child: child!),
        home: Material(
          child: Column(
            children: [
              TextField(controller: controller),
              TextButton(
                focusNode: buttonFocus,
                onPressed: () {},
                child: const Text('Other control'),
              ),
            ],
          ),
        ),
      ),
    );
    buttonFocus.requestFocus();
    await tester.pump();
    expect(await nativeSelectAll(), false);
    expect(controller.text, 'Preserve input');
    expect(controller.selection.isValid, false);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('outgoing frame cannot remove its replacement handler', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Replacement');
    addTearDown(controller.dispose);
    Widget tree(bool old) => MaterialApp(
      home: Material(
        child: Column(
          children: [
            if (old)
              const MacTextEditingActions(
                key: ValueKey('old'),
                child: Text('Outgoing frame'),
              ),
            MacTextEditingActions(
              key: const ValueKey('new'),
              child: TextField(controller: controller),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(tree(true));
    await tester.pumpWidget(tree(false));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(await nativeSelectAll(), true);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 11),
    );
    await tester.pumpWidget(const SizedBox());
    expect(await nativeSelectAll(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Windows keeps its existing editing path', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(child: MacTextEditingActions(child: TextField())),
      ),
    );
    expect(await nativeSelectAll(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
