import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_dialogs.dart';
import 'package:info_desktop/credential_history.dart';
import 'package:info_desktop/credential_use_approval.dart';
import 'package:info_desktop/focused_fill_ui.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/ui.dart';
import 'support/focused_fill_fixture.dart';

void viewport(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  double scale = 1,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Widget host(
  Widget child, [
  DesktopColorTheme theme = DesktopColorTheme.purple,
]) => MaterialApp(
  theme: informationTheme(theme),
  home: Scaffold(body: child),
);

Future<void> click(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await real(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

Future<T> real<T>(Future<T> Function() action) => action();

void fillTestWidgets(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    await tester.runAsync(() => body(tester));
  });
}

void main() {
  fillTestWidgets(
    'real inbox approves focused fill without a command plan or sending input',
    (tester) async {
      viewport(tester);
      final f = (await real(focusedFillFixture));
      addTearDown(() async {
        await tester.runAsync(f.service.close);
      });
      await tester.pumpWidget(InformationApp(service: f.service, port: 0));
      await tester.pumpAndSettle();
      expect(find.text('填充到哪里'), findsOneWidget);
      expect(find.text('GH_TOKEN'), findsNothing);
      await click(tester, 'fill-tip-02');
      expect(find.textContaining('相同应用中的其他页面'), findsOneWidget);
      await click(tester, 'focused-fill-lifetime');
      await tester.tap(find.text('4 小时').last);
      await tester.pumpAndSettle();
      await click(tester, 'focused-fill-approve');
      expect(find.textContaining('4 小时内'), findsOneWidget);
      await click(tester, 'fill-confirm-decision');
      final request = f.owner.credentialUseRequests.single;
      expect(
        request.credentialExpiresAt!.difference(request.decidedAt!),
        const Duration(hours: 4),
      );
      expect(request.approvedFields, isEmpty);
      expect(f.driver.sends, 0);
      expect(f.owner.focusedFillOperations, isEmpty);
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pump();
      await real(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byType(FocusedFillHistoryDocument), findsOneWidget);
      expect(find.textContaining('尚未填充'), findsOneWidget);
      expect(find.text('退出码'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  fillTestWidgets(
    'failed approval preserves draft, modal and no authority; retry persists once',
    (tester) async {
      viewport(tester);
      final f = (await real(focusedFillFixture));
      addTearDown(() async {
        await tester.runAsync(f.service.close);
      });
      final draft = CredentialUseApprovalDraft(const [])..minutes = 30;
      await tester.pumpWidget(
        host(
          CredentialUseApprovalPanel(
            owner: f.owner,
            request: f.request,
            draft: draft,
            onChanged: () {},
          ),
        ),
      );
      f.repository.fail = true;
      await click(tester, 'focused-fill-approve');
      await click(tester, 'fill-confirm-decision');
      expect(find.textContaining('审批未保存'), findsOneWidget);
      expect(f.owner.credentialUseState(f.request), 'pending');
      expect(draft.minutes, 30);
      expect(f.driver.sends, 0);
      f.repository.fail = false;
      await click(tester, 'fill-confirm-decision');
      expect(f.owner.credentialUseRequests.single.credentialApproved, isTrue);
      expect(f.owner.focusedFillOperations, isEmpty);
    },
  );

  fillTestWidgets('refusal does not create fill authority or input', (
    tester,
  ) async {
    viewport(tester);
    final f = (await real(focusedFillFixture));
    addTearDown(() async {
      await tester.runAsync(f.service.close);
    });
    await tester.pumpWidget(
      host(
        CredentialUseApprovalPanel(
          owner: f.owner,
          request: f.request,
          draft: CredentialUseApprovalDraft(const []),
          onChanged: () {},
        ),
      ),
    );
    await tester.tap(find.text('拒绝请求'));
    await tester.pumpAndSettle();
    await click(tester, 'fill-confirm-decision');
    expect(f.owner.credentialUseRequests.single.credentialApproved, isFalse);
    expect(
      f.owner.credentialUseState(f.owner.credentialUseRequests.single),
      'denied',
    );
    expect(f.driver.sends, 0);
  });

  fillTestWidgets(
    'unknown recovery is owner-confirmed, audited and does not resend or extend',
    (tester) async {
      viewport(tester);
      final f = (await real(() => focusedFillFixture(approved: true)));
      addTearDown(() async {
        await tester.runAsync(f.service.close);
      });
      f.driver.result = FocusedFillState.unknown;
      await real(() => f.fill('input-1'));
      final original = f.owner.focusedFillOperations.single;
      final expiry = f.owner.credentialUseRequests.single.credentialExpiresAt;
      final sends = f.driver.sends;
      await tester.pumpWidget(
        host(
          CredentialHistoryDocument(
            owner: f.owner,
            request: f.request,
            onChanged: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('结果未知'), findsWidgets);
      await click(tester, 'fill-acknowledge-attention');
      expect(
        f.owner.focusedFillOperations.single.attentionAcknowledgedAt,
        isNull,
      );
      f.repository.fail = true;
      await click(tester, 'fill-confirm-attention');
      expect(find.textContaining('确认未保存'), findsOneWidget);
      expect(
        f.owner.focusedFillOperations.single.attentionAcknowledgedAt,
        isNull,
      );
      f.repository.fail = false;
      await click(tester, 'fill-confirm-attention');
      final record = f.owner.focusedFillOperations.single;
      expect(record.attentionAcknowledgedAt, isNotNull);
      expect(record.id, original.id);
      expect(record.state, FocusedFillState.unknown);
      expect(f.driver.sends, sends);
      expect(f.owner.credentialUseRequests.single.credentialExpiresAt, expiry);
      expect(find.textContaining('已由用户确认目标'), findsOneWidget);
      expect(find.text('退出码'), findsNothing);
      expect(find.textContaining('synthetic-widget-password'), findsNothing);
    },
  );

  fillTestWidgets('active checking cannot be manually cleared', (tester) async {
    viewport(tester);
    final f = (await real(() => focusedFillFixture(approved: true)));
    addTearDown(() async {
      await tester.runAsync(f.service.close);
    });
    f.driver.wait = Completer<void>();
    await real(
      () => f.service.agent.startFocusedFill(f.session, f.operation('active')),
    );
    expect(
      f.owner.canAcknowledgeFocusedFillAttention(
        f.owner.focusedFillOperations.single.id,
      ),
      isFalse,
    );
    await tester.pumpWidget(
      host(
        FocusedFillOperations(
          owner: f.owner,
          request: f.request,
          onChanged: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('fill-acknowledge-attention')),
      findsNothing,
    );
    f.driver.wait!.complete();
    await real(f.service.drainFocusedFills);
  });

  fillTestWidgets(
    'string credential can be saved with an empty optional binding',
    (tester) async {
      viewport(tester);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(() async {
        await tester.runAsync(service.close);
      });
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CredentialEditor(owner: service.owner),
              ),
              child: const Text('create'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('create'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('credential-name')),
        '网页登录密码',
      );
      await tester.enterText(
        find.byKey(const ValueKey('credential-secret')),
        'synthetic-only',
      );
      await tester.enterText(
        find.byKey(const ValueKey('credential-binding')),
        '',
      );
      await click(tester, 'save-credential');
      expect(service.owner.credentials.single.suggestedBinding, '');
    },
  );

  fillTestWidgets(
    'terminal audit failure has an honest recovery entry, not an endless checking label',
    (tester) async {
      viewport(tester);
      final f = await focusedFillFixture(approved: true);
      addTearDown(() async {
        await tester.runAsync(f.service.close);
      });
      f.repository.failTerminal = true;
      await f.fill('audit-lost');
      expect(
        f.owner.focusedFillOperations.single.state,
        FocusedFillState.checking,
      );
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: FocusedFillOperations(
              owner: f.owner,
              request: f.request,
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('正在核验'), findsNothing);
      expect(find.text('结果未知'), findsWidgets);
      expect(find.textContaining('操作记录未能完整保存'), findsOneWidget);
      await click(tester, 'fill-acknowledge-attention');
      f.repository.failTerminal = false;
      await click(tester, 'fill-confirm-attention');
      expect(
        f.owner.focusedFillOperations.single.state,
        FocusedFillState.unknown,
      );
      expect(
        f.owner.focusedFillOperations.single.attentionAcknowledgedAt,
        isNotNull,
      );
    },
  );

  fillTestWidgets(
    'twenty operations stay bounded and page selection does not mix records',
    (tester) async {
      viewport(tester);
      final f = await focusedFillFixture(approved: true);
      addTearDown(() async {
        await tester.runAsync(f.service.close);
      });
      for (var i = 1; i <= 20; i++) {
        await f.fill('input-$i');
      }
      final sends = f.driver.sends;
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            child: FocusedFillOperations(
              owner: f.owner,
              request: f.request,
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('fill-operation-input-20')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('fill-operation-input-1')),
        findsNothing,
      );
      await click(tester, 'fill-operations-next');
      await click(tester, 'fill-operations-next');
      expect(
        find.byKey(const ValueKey('fill-operation-input-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('fill-operation-input-20')),
        findsNothing,
      );
      expect(find.text('显示 4 / 20 次'), findsOneWidget);
      await click(tester, 'fill-operation-input-1');
      expect(f.driver.sends, sends);
      expect(f.owner.focusedFillOperations.length, 20);
    },
  );

  for (final theme in DesktopColorTheme.values) {
    for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
      fillTestWidgets(
        'long focused-fill surfaces ${theme.name} ${size.width} at 200 percent',
        (tester) async {
          viewport(tester, size: size, scale: 2);
          final f = (await real(() => focusedFillFixture(long: true)));
          addTearDown(() async {
            await tester.runAsync(f.service.close);
          });
          await tester.pumpWidget(
            host(
              CredentialUseApprovalPanel(
                owner: f.owner,
                request: f.request,
                draft: CredentialUseApprovalDraft(const []),
                onChanged: () {},
              ),
              theme,
            ),
          );
          await tester.pumpAndSettle();
          await click(tester, 'fill-application-details');
          expect(tester.takeException(), isNull);
          await click(tester, 'focused-fill-approve');
          await click(tester, 'fill-confirm-decision');
          await tester.pumpWidget(
            host(
              CredentialHistoryDocument(
                owner: f.owner,
                request: f.request,
                onChanged: () {},
              ),
              theme,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
