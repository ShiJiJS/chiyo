import 'support/approval_interactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'support/desktop_platform_fixture.dart';

class _SettingsRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> writeSetting(String key, int value) async {
    if (fail) throw StateError('synthetic setting failure');
    await super.writeSetting(key, value);
  }
}

class _AuditRepository extends MemoryInformationRepository {
  bool fail = true;
  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    if (fail) throw StateError('synthetic audit failure');
    await super.saveGrantHistory(history);
  }
}

void main() {
  testWidgets(
    'slash focuses inbox outside editing and passes through in search input',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService.fictional();
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('inbox-search'));
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      final field = tester.widget<TextField>(search);
      expect(field.focusNode!.hasFocus, isTrue);
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        handled,
        isFalse,
        reason: 'The focused editor must receive the slash text key.',
      );
      await tester.enterText(search, '/');
      expect(field.controller!.text, '/');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('slash preserves the custom lifetime editor focus and text key', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService.fictional();
    addTearDown(() async {
      final closing = service.close();
      await tester.pump();
      await closing;
    });
    final session = service.agent.openSession('Keyboard lifetime draft');
    final request = service.agent.request(session, 'Synthetic keyboard check', [
      const FieldRef('demo-server', 'host'),
    ]);
    await tester.pumpWidget(InformationApp(service: service, port: 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('grant-lifetime-${request.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…').last);
    await tester.pumpAndSettle();
    final input = find.byType(TextFormField);
    await tester.tap(input);
    await tester.pumpAndSettle();
    final editor = tester.widget<EditableText>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    );
    expect(editor.focusNode.hasFocus, isTrue);
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(
      editor.focusNode.hasFocus,
      isTrue,
      reason: 'Editing a lifetime must not focus the underlying inbox.',
    );
    expect(
      handled,
      isFalse,
      reason: 'The focused lifetime editor owns the slash text key.',
    );
    await tester.enterText(input, '90');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存期限'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<int>>(
            find.byKey(ValueKey('grant-lifetime-${request.id}')),
          )
          .value,
      90,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'a changed target preserves the pending selection and can be corrected',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MemoryInformationRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Address', '', 'example.invalid'),
        const FieldInput('Removed field', '', 'old'),
      ]);
      final session = service.agent.openSession('Changed target');
      final request = service.agent.request(
        session,
        'Read connection',
        item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
      );
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await repository.save(
        InformationItem(item.id, item.name, '', 2, [item.fields.first]),
      );
      await tester.tap(find.byKey(const ValueKey('approve-selection')));
      await tester.pumpAndSettle();
      expect(service.agent.status(session, request.id)['status'], 'pending');
      expect(find.textContaining('所选字段已不可用，或超过200个'), findsOneWidget);
      final unavailable = find.byKey(ValueKey('field-${item.fields.last.id}'));
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: unavailable, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      await tester.tap(unavailable);
      await tester.tap(find.byKey(const ValueKey('approve-selection')));
      await tester.pumpAndSettle();
      expect(service.agent.claim(session, request.id).fields, [
        FieldRef(item.id, item.fields.first.id),
      ]);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
  testWidgets(
    'failed audit keeps the actual terminal approval and retries only saving',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _AuditRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'example.invalid'),
      ]);
      final session = service.agent.openSession('Audit chat');
      final request = service.agent.request(session, 'Read address', [
        FieldRef(item.id, item.fields.single.id),
      ]);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approve-selection')));
      await tester.pumpAndSettle();
      expect(service.agent.status(session, request.id)['status'], 'approved');
      expect(find.text('批准所选字段'), findsNothing);
      expect(find.textContaining('决定已记录'), findsOneWidget);
      repository.fail = false;
      await tester.tap(find.text('重试保存记录'));
      await tester.pumpAndSettle();
      expect(service.owner.auditStorageUnavailable, isFalse);
      expect((await service.owner.history()).grants, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
  testWidgets(
    'notification opens its request on another page and clears stale search',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService.fictional(clock: () => now);
      final native = NativeDesktopFixture();
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await tester.runAsync(runtime.start);
      final ids = <String>[];
      for (var i = 0; i < 45; i++) {
        final session = service.agent.openSession('Notice $i');
        ids.add(
          service.agent.request(session, 'Notice purpose $i', [
            const FieldRef('demo-server', 'host'),
          ]).id,
        );
        now = now.add(const Duration(seconds: 1));
      }
      await tester.pumpWidget(
        InformationApp(service: service, port: 0, runtime: runtime),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inbox-search')),
        'absent',
      );
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      native.openedRequestId = ids.first;
      await tester.runAsync(
        () => runtime.handleEvent(DesktopEvent.openApprovals),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notice purpose 0'), findsOneWidget);
      expect(find.byKey(ValueKey('request-${ids.first}')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
    },
  );
  testWidgets(
    'large inbox pages and searches while preserving per-request decisions',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService.fictional(clock: () => now);
      final ids = <String>[];
      for (var i = 0; i < 61; i++) {
        final session = service.agent.openSession('Queue $i');
        ids.add(
          service.agent.request(session, 'Purpose $i', [
            const FieldRef('demo-server', 'host'),
          ]).id,
        );
        now = now.add(const Duration(seconds: 1));
      }
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(find.text('Purpose 60'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('inbox-search')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await selectGrantMinutes(
        tester,
        find.byKey(ValueKey('grant-lifetime-${ids.last}')),
        15,
      );
      await tester.tap(find.byKey(const ValueKey('field-host')));
      await tester.tap(find.byTooltip('下一页请求'));
      await tester.pumpAndSettle();
      expect(find.text('Purpose 52'), findsOneWidget);
      await tester.tap(find.byTooltip('上一页请求'));
      await tester.pumpAndSettle();
      expect(find.text('Purpose 60'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve-selection')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('inbox-search')),
        'absent',
      );
      await tester.pumpAndSettle();
      expect(find.text('Purpose 60'), findsNothing);
      expect(find.text('没有找到请求'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('inbox-search')),
        'Queue 0',
      );
      await tester.pumpAndSettle();
      expect(find.text('Purpose 0'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('inbox-search')), '');
      await tester.pumpAndSettle();
      final selectedPurpose = find.text('Purpose 60');
      expect(selectedPurpose, findsOneWidget);
      for (var i = 0; i < 25; i++) {
        now = now.add(const Duration(seconds: 1));
        final session = service.agent.openSession('Arriving $i');
        service.agent.request(session, 'New request $i', [
          const FieldRef('demo-server', 'host'),
        ]);
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(selectedPurpose, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
  testWidgets(
    'theme changes reach existing pages, reopen, and recover from failed writes',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _SettingsRepository();
      final service = InformationService(repository: repository);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      final initial = Theme.of(
        tester.element(find.byKey(const ValueKey('nav-0'))),
      ).colorScheme;
      await tester.tap(find.byKey(const ValueKey('theme-green')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      final green = Theme.of(tester.element(find.text('新建信息'))).colorScheme;
      expect(green.primary, isNot(initial.primary));
      expect(green.surfaceContainerLow, isNot(initial.surfaceContainerLow));
      expect(service.owner.colorTheme, DesktopColorTheme.green);
      repository.fail = true;
      await tester.tap(find.byKey(const ValueKey('theme-blue')));
      await tester.pumpAndSettle();
      expect(find.textContaining('主题未保存'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('新建信息'))).colorScheme.primary,
        green.primary,
      );
      repository.fail = false;
      await tester.tap(find.byKey(const ValueKey('theme-blue')));
      await tester.pumpAndSettle();
      expect(find.textContaining('主题未保存'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(service.owner.colorTheme, DesktopColorTheme.blue);
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('nav-0'))),
        ).colorScheme.primary,
        isNot(green.primary),
      );
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
}
