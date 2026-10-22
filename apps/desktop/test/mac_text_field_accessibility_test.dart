import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/mac_text_field_accessibility.dart';

void main() {
  const channel = MethodChannel('agent_info_manage/text_field_accessibility');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'native metadata contains only purpose and visible geometry, updates on scroll and clears',
    (tester) async {
      final controller = TextEditingController(text: 'synthetic-private-value');
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 120,
                child: SingleChildScrollView(
                  controller: scroll,
                  child: Column(
                    children: [
                      const SizedBox(height: 40),
                      MacTextFieldAccessibility(
                        label: '公开说明',
                        child: TextField(controller: controller),
                      ),
                      const SizedBox(height: 400),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = (calls.last.arguments as List).single as Map;
      expect(calls.last.method, 'update');
      expect(first.keys.toSet(), {'label', 'left', 'top', 'width', 'height'});
      expect(first['label'], '公开说明');
      expect(calls.toString(), isNot(contains(controller.text)));
      scroll.jumpTo(20);
      await tester.pumpAndSettle();
      final moved = (calls.last.arguments as List).single as Map;
      expect(moved['top'], (first['top'] as double) - 20);
      scroll.jumpTo(250);
      await tester.pumpAndSettle();
      expect(calls.last.arguments, isEmpty);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(calls.last.arguments, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last.arguments, isEmpty);
      controller.dispose();
      scroll.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'concrete scroll position replacements keep geometry updates live',
    (tester) async {
      final scroll = ScrollController();
      late StateSetter update;
      ScrollPhysics physics = const ClampingScrollPhysics();
      final input = MacTextFieldAccessibility(
        label: '公开说明',
        child: const TextField(),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, change) {
                  update = change;
                  return SizedBox(
                    width: 300,
                    height: 120,
                    child: SingleChildScrollView(
                      controller: scroll,
                      physics: physics,
                      child: Column(
                        children: [
                          const SizedBox(height: 40),
                          input,
                          const SizedBox(height: 400),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        final original = scroll.position;
        update(() => physics = const BouncingScrollPhysics());
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(Scrollable).first), same(state));
        expect(scroll.position, isNot(same(original)));
        final before = (calls.last.arguments as List).single as Map;
        scroll.jumpTo(20);
        await tester.pumpAndSettle();
        final after = (calls.last.arguments as List).single as Map;
        expect(after['top'], (before['top'] as double) - 20);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        scroll.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'other platforms keep framework semantics without native messages',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MacTextFieldAccessibility(label: '名称', child: TextField()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        tester.getSemantics(find.byType(EditableText)).getSemanticsData().label,
        '名称',
      );
      await tester.pumpWidget(const SizedBox());
      expect(calls, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
