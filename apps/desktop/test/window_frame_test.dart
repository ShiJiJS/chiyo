import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/window_frame.dart';

void main() {
  const channel = MethodChannel('agent_info_manage/window');
  testWidgets('caption controls remain accessible above the workspace route', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final semantics = tester.ensureSemantics();
    final commands = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      commands.add(call.method);
      return call.method == 'enableCustomFrame' ? false : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopWindowFrame(child: child!),
          home: const Scaffold(body: Text('Workspace')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        containsAll([
          isSemantics(tooltip: '最小化', isButton: true, hasTapAction: true),
          isSemantics(tooltip: '最大化', isButton: true, hasTapAction: true),
          isSemantics(tooltip: '关闭窗口', isButton: true, hasTapAction: true),
          isSemantics(label: 'Workspace'),
        ]),
      );
      expect(tester.getTopLeft(find.byType(Scaffold)).dy, 34);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('window-close'))).dy,
        0,
      );
      tester.semantics.performAction(
        find.semantics.byPredicate(
          (node) => node.getSemanticsData().tooltip == '最小化',
        ),
        SemanticsAction.focus,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(commands, ['enableCustomFrame', 'minimize']);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(commands.last, 'toggleMaximize');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(commands.last, 'close');
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });
  testWidgets(
    'custom caption routes controls to native host and supports dragging',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final commands = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        commands.add(call.method);
        return call.method == 'enableCustomFrame' ? false : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopWindowFrame(child: child!),
          home: const Scaffold(body: Text('Workspace')),
        ),
      );
      await tester.pumpAndSettle();
      expect(commands, ['enableCustomFrame']);
      expect(find.text('Workspace'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('window-minimize')));
      await tester.tap(find.byKey(const ValueKey('window-toggleMaximize')));
      await tester.drag(
        find.byKey(const ValueKey('window-drag')),
        const Offset(80, 0),
      );
      await tester.tap(find.byKey(const ValueKey('window-close')));
      await tester.pumpAndSettle();
      expect(commands, [
        'enableCustomFrame',
        'minimize',
        'toggleMaximize',
        'drag',
        'close',
      ]);
      await tester.longPress(find.byKey(const ValueKey('window-minimize')));
      await tester.pumpAndSettle();
      expect(find.text('最小化'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('a host without custom-caption support keeps workspace usable', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopWindowFrame(child: child!),
        home: const Scaffold(body: Text('Workspace')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('window-close')), findsNothing);
    expect(find.text('Workspace'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'launcher replacement keeps native maximize-state updates connected',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'enableCustomFrame' ? false : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      Widget app(String key) => MaterialApp(
        builder: (_, child) =>
            DesktopWindowFrame(key: ValueKey(key), child: child!),
        home: const Scaffold(body: Text('Workspace')),
      );
      await tester.pumpWidget(app('launcher'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app('ready'));
      await tester.pumpAndSettle();
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('state', true),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('还原窗口'), findsOneWidget);
      expect(find.byTooltip('最大化'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
