import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_dialogs.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/ui.dart';

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });
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
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  Finder editable(Finder parent) =>
      find.descendant(of: parent, matching: find.byType(EditableText));
  void purpose(WidgetTester tester, Finder parent, String label) {
    final data = tester.getSemantics(editable(parent)).getSemanticsData();
    expect(data.flagsCollection.isTextField, isTrue);
    // An empty input can also announce its visible hint after the stable
    // purpose. It must not merge with the surrounding page's headings.
    expect(data.label, startsWith(label));
  }

  testWidgets(
    'shared and credential fields retain purpose and actions without native secret metadata',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final name = TextEditingController(text: 'Synthetic existing name');
      final secret = TextEditingController(text: 'synthetic-private-secret');
      final credential = TextEditingController();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: informationTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    DesktopTextField(
                      key: const ValueKey('name'),
                      controller: name,
                      decoration: const InputDecoration(labelText: '显示名称'),
                    ),
                    const DesktopTextFormField(
                      key: ValueKey('reason'),
                      initialValue: 'Synthetic reason',
                      decoration: InputDecoration(labelText: '申请原因'),
                    ),
                    const DesktopTextField(
                      key: ValueKey('search'),
                      decoration: InputDecoration(hintText: '搜索请求'),
                    ),
                    credentialInput(
                      context,
                      '凭据名称',
                      credential,
                      key: const ValueKey('credential'),
                    ),
                    DesktopTextField(
                      controller: secret,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '秘密内容'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final entry in {
          'name': '显示名称',
          'reason': '申请原因',
          'search': '搜索请求',
          'credential': '凭据名称',
        }.entries) {
          purpose(tester, find.byKey(ValueKey(entry.key)), entry.value);
        }
        await tester.tap(editable(find.byKey(const ValueKey('name'))));
        await tester.pumpAndSettle();
        final node = tester.getSemantics(
          editable(find.byKey(const ValueKey('name'))),
        );
        tester.semantics.performAction(
          find.semantics.byPredicate((n) => n.id == node.id),
          SemanticsAction.setText,
          args: 'Updated synthetic name',
        );
        await tester.pumpAndSettle();
        expect(name.text, 'Updated synthetic name');
        expect(secret.text, 'synthetic-private-secret');
        if (debugDefaultTargetPlatformOverride == TargetPlatform.macOS) {
          expect(
            (calls.last.arguments as List).map((e) => e['label']).toSet(),
            {'显示名称', '申请原因', '搜索请求', '凭据名称'},
          );
          expect(calls.toString(), isNot(contains(secret.text)));
          expect(calls.toString(), isNot(contains(name.text)));
        } else {
          expect(calls, isEmpty);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        semantics.dispose();
        name.dispose();
        secret.dispose();
        credential.dispose();
      }
    },
    variant: platforms,
  );

  testWidgets(
    'ordinary app searches and template fields keep purpose with populated values',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      try {
        await tester.pumpWidget(InformationApp(service: service, port: 0));
        await tester.pumpAndSettle();
        for (final entry in [
          ('nav-0', 'inbox-search', '搜索聊天、信息名称'),
          ('nav-1', 'library-search', '搜索信息'),
          ('nav-2', 'proposal-search', '搜索提案、提交方'),
          ('nav-3', 'history-search', '搜索聊天、Agent、记录编号'),
        ]) {
          await tester.tap(find.byKey(ValueKey(entry.$1)));
          await tester.pumpAndSettle();
          final search = find.byKey(ValueKey(entry.$2));
          purpose(tester, search, entry.$3);
          if (debugDefaultTargetPlatformOverride == TargetPlatform.macOS) {
            expect(
              (calls.last.arguments as List).map((e) => e['label']).toList(),
              [entry.$3],
            );
          }
          await tester.enterText(search, 'Synthetic query');
          await tester.pumpAndSettle();
          purpose(tester, search, entry.$3);
        }
        await tester.tap(find.byKey(const ValueKey('nav-4')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-section-templates')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('新建模板'));
        await tester.pumpAndSettle();
        purpose(tester, find.byKey(const ValueKey('template-name')), '模板名称');
        purpose(
          tester,
          find.byKey(const ValueKey('template-field-name-0')),
          '字段名称',
        );
        await tester.enterText(
          find.byKey(const ValueKey('template-name')),
          'Synthetic template',
        );
        await tester.enterText(
          find.byKey(const ValueKey('template-field-name-0')),
          'Synthetic field',
        );
        await tester.tap(find.text('编辑说明'));
        await tester.pumpAndSettle();
        for (final label in ['模板说明', '字段 1 说明']) {
          expect(find.semantics.byLabel(label), findsOneWidget);
        }
        await tester.tap(find.text('保存模板'));
        await tester.pumpAndSettle();
        expect(service.owner.templates.single.name, 'Synthetic template');
        expect(
          service.owner.templates.single.fields.single.name,
          'Synthetic field',
        );
        expect(service.owner.information, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        semantics.dispose();
        final closing = service.close();
        await tester.pump();
        await closing;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    variant: platforms,
  );
}
