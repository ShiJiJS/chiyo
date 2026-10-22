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
    'ordinary AX cache follows actual controller values and visible geometry',
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
      expect(first.keys.toSet(), {
        'label',
        'left',
        'top',
        'width',
        'height',
        'text',
      });
      expect(first['label'], '公开说明');
      expect(first['text'], controller.text);
      controller.text = 'synthetic-new-value';
      await tester.pumpAndSettle();
      expect((calls.last.arguments as List).single['text'], controller.text);
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

  testWidgets('obscured text never enters ordinary native AX cache messages', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'synthetic-secret');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacTextFieldAccessibility(
            label: '秘密',
            child: TextField(controller: controller, obscureText: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect((calls.last.arguments as List).single.containsKey('text'), isFalse);
    expect(calls.toString(), isNot(contains(controller.text)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'controller replacement drops old subscriptions and publishes current value',
    (tester) async {
      final first = TextEditingController(text: 'synthetic-first');
      final second = TextEditingController(text: 'synthetic-second');
      var current = first;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, change) {
                update = change;
                return MacTextFieldAccessibility(
                  label: '名称',
                  child: TextField(controller: current),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      update(() => current = second);
      await tester.pumpAndSettle();
      expect((calls.last.arguments as List).single['text'], second.text);
      calls.clear();
      first.text = 'synthetic-stale';
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      second.text = 'synthetic-current';
      await tester.pumpAndSettle();
      expect((calls.last.arguments as List).single['text'], second.text);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      first.dispose();
      second.dispose();
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
    'retained indexed pages publish only the currently visible field purpose',
    (tester) async {
      late StateSetter update;
      int? index = 0;
      var visible = true;
      const children = [
        MacTextFieldAccessibility(label: '搜索请求', child: TextField()),
        MacTextFieldAccessibility(label: '搜索历史', child: TextField()),
      ];
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, change) {
                  update = change;
                  return Visibility(
                    visible: visible,
                    maintainState: true,
                    child: IndexedStack(index: index, children: children),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final originalStates = tester
            .stateList(
              find.byType(MacTextFieldAccessibility, skipOffstage: false),
            )
            .toList();
        List<Object?> labels() =>
            (calls.last.arguments as List).map((e) => e['label']).toList();
        expect(labels(), ['搜索请求']);
        update(() => index = 1);
        await tester.pumpAndSettle();
        expect(
          tester
              .stateList(
                find.byType(MacTextFieldAccessibility, skipOffstage: false),
              )
              .toList(),
          originalStates,
        );
        expect(labels(), ['搜索历史']);
        update(() => visible = false);
        await tester.pumpAndSettle();
        expect(labels(), isEmpty);
        update(() => visible = true);
        await tester.pumpAndSettle();
        expect(labels(), ['搜索历史']);
        update(() => index = null);
        await tester.pumpAndSettle();
        expect(labels(), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
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
