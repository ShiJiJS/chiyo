import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/mac_text_editing.dart';

Future<Object?> nativeAction(String method) async {
  final result = Completer<ByteData?>();
  const codec = StandardMethodCodec();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'agent_info_manage/text_editing',
        codec.encodeMethodCall(MethodCall(method)),
        result.complete,
      );
  final reply = await result.future;
  return reply == null ? null : codec.decodeEnvelope(reply);
}

Future<Object?> nativeSelectAll() => nativeAction('selectAll');

void main() {
  testWidgets('native undo and redo use only the focused editor history', (
    tester,
  ) async {
    final first = TextEditingController(text: 'Original first');
    final second = TextEditingController(text: 'Original second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MacTextEditingActions(child: child!),
        home: Material(
          child: Column(
            children: [
              TextField(key: const ValueKey('first'), controller: first),
              TextField(key: const ValueKey('second'), controller: second),
            ],
          ),
        ),
      ),
    );
    for (final field in ['first', 'second']) {
      await tester.tap(find.byKey(ValueKey(field)));
      await tester.pump(const Duration(seconds: 1));
      await tester.enterText(find.byKey(ValueKey(field)), 'Changed $field');
      await tester.pump(const Duration(seconds: 1));
    }
    expect(await nativeAction('undo'), true);
    await tester.pump();
    expect(first.text, 'Changed first');
    expect(second.text, 'Original second');
    expect(await nativeAction('redo'), true);
    await tester.pump();
    expect(second.text, 'Changed second');
    await tester.tap(find.byKey(const ValueKey('first')));
    expect(await nativeAction('undo'), true);
    await tester.pump();
    expect(first.text, 'Original first');
    expect(second.text, 'Changed second');
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native undo cannot change an editor switched to read-only', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Original');
    addTearDown(controller.dispose);
    late StateSetter rebuild;
    var readOnly = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MacTextEditingActions(child: child!),
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TextField(controller: controller, readOnly: readOnly);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'Changed');
    await tester.pump(const Duration(seconds: 1));
    rebuild(() => readOnly = true);
    await tester.pump();
    expect(await nativeAction('undo'), false);
    expect(await nativeAction('redo'), false);
    expect(controller.text, 'Changed');
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'native clipboard actions update the focused model and clipboard',
    (tester) async {
      final first = TextEditingController(text: '中文 合成粘贴 Clipboard');
      final second = TextEditingController(text: 'Replace me');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard != null};
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
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => MacTextEditingActions(child: child!),
          home: Material(
            child: Column(
              children: [
                TextField(key: const ValueKey('source'), controller: first),
                TextField(key: const ValueKey('target'), controller: second),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('source')));
      await nativeSelectAll();
      expect(await nativeAction('copy'), true);
      await tester.pump();
      expect(clipboard, first.text);
      await tester.tap(find.byKey(const ValueKey('target')));
      await nativeSelectAll();
      expect(await nativeAction('paste'), true);
      await tester.pump();
      expect(second.text, first.text);
      expect(
        second.selection,
        TextSelection.collapsed(offset: first.text.length),
      );
      await nativeSelectAll();
      expect(await nativeAction('cut'), true);
      await tester.pump();
      expect(second.text, isEmpty);
      expect(first.text, '中文 合成粘贴 Clipboard');
      expect(clipboard, first.text);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'native clipboard actions preserve read-only and obscured fields',
    (tester) async {
      final readOnly = TextEditingController(text: 'Read only');
      final secret = TextEditingController(text: 'Synthetic secret');
      addTearDown(readOnly.dispose);
      addTearDown(secret.dispose);
      var clipboard = 'Clipboard sentinel';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => MacTextEditingActions(child: child!),
          home: Material(
            child: Column(
              children: [
                TextField(
                  key: const ValueKey('readonly'),
                  controller: readOnly,
                  readOnly: true,
                ),
                TextField(
                  key: const ValueKey('secret'),
                  controller: secret,
                  obscureText: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('readonly')));
      await nativeSelectAll();
      expect(await nativeAction('cut'), true);
      expect(await nativeAction('paste'), true);
      await tester.pump();
      expect(readOnly.text, 'Read only');
      expect(clipboard, 'Clipboard sentinel');
      await tester.tap(find.byKey(const ValueKey('secret')));
      await nativeSelectAll();
      expect(await nativeAction('copy'), true);
      expect(await nativeAction('cut'), true);
      await tester.pump();
      expect(secret.text, 'Synthetic secret');
      expect(clipboard, 'Clipboard sentinel');
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

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
    for (final method in ['copy', 'cut', 'paste', 'undo', 'redo']) {
      expect(await nativeAction(method), false);
    }
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
    for (final method in ['copy', 'cut', 'paste', 'undo', 'redo']) {
      expect(await nativeAction(method), isNull);
    }
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
