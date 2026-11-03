import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/mac_inline_password.dart';
import 'package:info_desktop/desktop_controls.dart';

void main() {
  testWidgets(
    'Mac password is inline and private; native edits update only its Host draft',
    (t) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final controller = TextEditingController();
      final changes = <String>[];
      MethodChannel? channel;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async => null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        if (channel != null) messenger.setMockMethodCallHandler(channel, null);
        controller.dispose();
      });
      var enabled = true;
      var obscured = true;
      Future<void> show() async {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DesktopTextField(
                controller: controller,
                enabled: enabled,
                obscureText: obscured,
                inlineSecret: true,
                decoration: const InputDecoration(labelText: '密码'),
                onChanged: changes.add,
              ),
            ),
          ),
        );
        await t.pump();
      }

      await show();
      final view = t.widget<AppKitView>(find.byType(AppKitView));
      final viewState = t.state(find.byType(AppKitView));
      // A mock platform view supplies no native text node. Exercise the same
      // private callback used by NSSecureTextField without logging its payload.
      const id = 718;
      channel = const MethodChannel('agent_info_manage/inline_password/718');
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      view.onPlatformViewCreated!(id);
      await t.pump();
      Future<void> input(String value) async {
        final done = Completer<void>();
        await messenger.handlePlatformMessage(
          channel!.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('changed', value),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await t.pump();
      }

      await input('SYNTHETIC-INLINE');
      expect(controller.text, 'SYNTHETIC-INLINE');
      expect(changes, ['SYNTHETIC-INLINE']);
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('填写'), findsNothing);
      expect(find.text('SYNTHETIC-INLINE'), findsNothing);
      obscured = false;
      await show();
      expect(t.state(find.byType(AppKitView)), same(viewState));
      expect(
        t.widget<MacInlinePassword>(find.byType(MacInlinePassword)).obscureText,
        false,
      );
      obscured = true;
      await show();
      expect(t.state(find.byType(AppKitView)), same(viewState));
      expect(
        t.getSemantics(find.byType(MacInlinePassword)).toStringDeep(),
        isNot(contains('SYNTHETIC-INLINE')),
      );
      await input('bad\u0000input');
      expect(controller.text, 'SYNTHETIC-INLINE');
      enabled = false;
      await show();
      await input('DISABLED');
      expect(controller.text, 'SYNTHETIC-INLINE');
      await t.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
