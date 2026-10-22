import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/mac_secret_input.dart';
import 'package:info_desktop/credential_dialogs.dart';
import 'package:info_desktop/credential_management.dart';
import 'package:info_desktop/ui.dart';
import 'support/credential_maintenance_fixture.dart';

const channel = MethodChannel('agent_info_manage/secret_editor');
void main() {
  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  Future<void> show(
    WidgetTester tester,
    TextEditingController controller, {
    int? limit,
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MacSecretInput(
          controller: controller,
          label: '凭据内容',
          enabled: enabled,
          maxLength: limit,
        ),
      ),
    ),
  );
  Future<void> edit(WidgetTester tester) async {
    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
  }

  void noSecret(WidgetTester tester, String secret) {
    expect(find.byType(EditableText), findsNothing);
    expect(
      tester.getSemantics(find.byType(MacSecretInput)).toStringDeep(),
      isNot(contains(secret)),
    );
  }

  testWidgets(
    'Mac secret draft accepts cancels clears and never creates an editable semantic node',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController(text: 'synthetic-old-secret');
      addTearDown(controller.dispose);
      var result = 'synthetic-new-secret';
      var cancel = false;
      final calls = <MethodCall>[];
      mock((call) async {
        calls.add(call);
        return call.method == 'edit' && !cancel ? result : null;
      });
      await show(tester, controller);
      noSecret(tester, controller.text);
      await edit(tester);
      expect(controller.text, result);
      expect(calls.single.arguments['initial'], 'synthetic-old-secret');
      noSecret(tester, result);
      cancel = true;
      await edit(tester);
      expect(controller.text, result);
      cancel = false;
      result = '';
      await edit(tester);
      expect(controller.text, isEmpty);
      expect(find.text('未填写'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'pending secret editor rejects reentry and stale controller writes and cancels on disposal',
    (tester) async {
      final controller = TextEditingController(text: 'initial');
      addTearDown(controller.dispose);
      var pending = Completer<Object?>();
      final calls = <MethodCall>[];
      mock((call) async {
        calls.add(call);
        return call.method == 'edit' ? pending.future : null;
      });
      await show(tester, controller);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      controller.text = 'changed elsewhere';
      pending.complete('late secret');
      await tester.pumpAndSettle();
      expect(controller.text, 'changed elsewhere');
      expect(calls.where((c) => c.method == 'edit'), hasLength(1));
      pending = Completer<Object?>();
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last.method, 'cancel');
      expect(
        calls.last.arguments['requestId'],
        calls[calls.length - 2].arguments['requestId'],
      );
      pending.complete('discarded');
      await tester.pumpAndSettle();
      expect(controller.text, 'changed elsewhere');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'native response is validated for NUL UTF8 byte and grapheme limits',
    (tester) async {
      final controller = TextEditingController(text: 'old');
      addTearDown(controller.dispose);
      var result = 'bad\u0000value';
      mock((call) async => call.method == 'edit' ? result : null);
      await show(tester, controller, limit: 2);
      await edit(tester);
      expect(controller.text, 'old');
      result = 'a' * 65537;
      await edit(tester);
      expect(controller.text, 'old');
      result = 'abc';
      await edit(tester);
      expect(controller.text, 'old');
      result = '👩🏽‍💻é';
      await edit(tester);
      expect(controller.text, result);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'editor failure and disabled state preserve draft and do not expose native error detail',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController(text: 'synthetic-private');
      addTearDown(controller.dispose);
      var count = 0;
      mock((call) async {
        count++;
        throw PlatformException(code: 'failure', message: controller.text);
      });
      await show(tester, controller, enabled: false);
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      expect(count, 0);
      await show(tester, controller);
      await edit(tester);
      expect(controller.text, 'synthetic-private');
      expect(find.text('无法编辑，请重试'), findsOneWidget);
      noSecret(tester, controller.text);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'actual Mac credential create and rotate keep drafts on save failure and only persist on parent save',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MaintenanceRepository()..fail = true;
      final service = InformationService(repository: repository);
      var value = 'synthetic-create-value';
      mock((call) async => call.method == 'edit' ? value : null);
      Future<void> open(Widget child) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: informationTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showDialog<void>(context: context, builder: (_) => child),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      await open(CredentialEditor(owner: service.owner));
      await tester.enterText(
        find.byKey(const ValueKey('credential-name')),
        'Mac native secret',
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('credential-secret')),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.owner.credentials, isEmpty);
      await tester.tap(find.byKey(const ValueKey('save-credential')));
      await tester.pumpAndSettle();
      expect(service.owner.credentials, isEmpty);
      expect(find.text('已填写'), findsOneWidget);
      repository.fail = false;
      await tester.tap(find.byKey(const ValueKey('save-credential')));
      await tester.pumpAndSettle();
      final c = service.owner.credentials.single;
      expect(c.version, 1);
      expect(utf8.decode(repository.credentialMaterials.single.bytes), value);
      value = 'synthetic-rotated-value';
      await open(
        CredentialManagement(
          owner: service.owner,
          credential: c,
          action: 'rotate',
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('credential-new-secret')),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.owner.credentials.single.version, 1);
      repository.fail = true;
      await tester.tap(
        find.byKey(const ValueKey('save-credential-management')),
      );
      await tester.pumpAndSettle();
      expect(service.owner.credentials.single.version, 1);
      expect(find.text('已填写'), findsOneWidget);
      repository.fail = false;
      await tester.tap(
        find.byKey(const ValueKey('save-credential-management')),
      );
      await tester.pumpAndSettle();
      expect(service.owner.credentials.single.version, 2);
      expect(
        utf8.decode(
          repository.credentialMaterials
              .singleWhere((m) => m.version == 2)
              .bytes,
        ),
        value,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('Windows retains its existing secret TextField path', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                credentialInput(context, '内容', controller, secret: true),
                DesktopTextField(obscureText: true, controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(MacSecretInput), findsNothing);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .every((f) => f.obscureText),
      true,
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
