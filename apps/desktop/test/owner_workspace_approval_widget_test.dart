import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/owner_workspace_approvals.dart';
import 'package:info_desktop/workspace/workspace_approvals.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      if (done()) {
        await t.pumpAndSettle();
        return;
      }
    }
    fail('Owner decision did not settle');
  }

  for (final approve in [true, false]) {
    testWidgets(
      'real owner page ${approve ? 'approves and revokes' : 'denies'} an Agent request',
      (t) async {
        t.view.physicalSize = const Size(1440, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final service = core.InformationService(
          repository: core.MemoryInformationRepository(),
        );
        final item = await service.owner.createInformation('合成资料', '', [
          const core.FieldInput('合成字段', '', 'SYNTHETIC'),
        ]);
        final field = core.FieldRef(item.id, item.fields.single.id);
        final session = service.agent.openSession('合成聊天');
        final request = service.agent.request(session, '控件验收', [field]);
        final model = ApprovalsController(
          OwnerWorkspaceApprovals(owner: service.owner),
          const Stream.empty(),
        );
        unawaited(model.load());
        await settle(
          t,
          () => !model.loading && !model.reading && model.detail != null,
        );
        await t.pumpWidget(
          MaterialApp(
            theme: zhiyuTheme(Brightness.light),
            home: Scaffold(
              body: ApprovalsPage(controller: model, onRecord: (_) {}),
            ),
          ),
        );
        await t.pumpAndSettle();
        final action = find.byKey(
          ValueKey(approve ? 'approval-approve' : 'approval-deny'),
        );
        await t.ensureVisible(action);
        await t.tap(action);
        await settle(
          t,
          () =>
              !model.busy &&
              !model.loading &&
              !model.reading &&
              model.detail!.request.state != WorkspaceApprovalState.pending,
        );
        expect(model.writeFailure, isNull);
        if (approve) {
          final grant = service.agent.claim(session, request.id);
          expect(await service.agent.read(grant.token, field), 'SYNTHETIC');
          final revoke = find.byKey(const ValueKey('approval-revoke'));
          await t.ensureVisible(revoke);
          await t.tap(revoke);
          await settle(
            t,
            () =>
                !model.busy &&
                !model.loading &&
                !model.reading &&
                model.detail!.request.state == WorkspaceApprovalState.revoked,
          );
          await expectLater(
            service.agent.read(grant.token, field),
            throwsA(isA<core.AccessFailure>()),
          );
        } else {
          expect(service.agent.status(session, request.id)['status'], 'denied');
          expect(
            () => service.agent.claim(session, request.id),
            throwsA(isA<core.AccessFailure>()),
          );
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        model.dispose();
        var closed = false;
        final closing = service.close().then((_) => closed = true);
        await settle(t, () => closed);
        await closing;
      },
    );
  }
}
