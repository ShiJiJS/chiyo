import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/owner_workspace_grant_history.dart';
import 'package:info_desktop/workspace/owner_workspace_approvals.dart';
import 'package:info_desktop/workspace/workspace_grant_history.dart';
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
    fail('Real history did not settle');
  }

  testWidgets(
    'real history renders access results and its revoke button blocks further reads',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final service = core.InformationService(
        repository: core.MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('字段', '', 'SYNTHETIC'),
      ]);
      final field = core.FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('真实服务测试');
      final r = service.agent.request(session, '查看资料', [field]);
      var approved = false;
      final approving = service.owner
          .decideInformationRequest(
            core.InformationApprovalCommand(
              operationId: 'widget-approve',
              requestId: r.id,
              action: core.InformationApprovalAction.approve,
              reviewToken: 'a' * 64,
              commandDigest: 'b' * 64,
              fields: [field],
              itemVersions: {item.id: item.version},
            ),
          )
          .then((_) => approved = true);
      await settle(t, () => approved);
      await approving;
      final bearer = service.agent.claim(session, r.id).token;
      expect(await service.agent.read(bearer, field), 'SYNTHETIC');
      final model = GrantHistoryController(
        OwnerWorkspaceGrantHistory(owner: service.owner),
        OwnerWorkspaceApprovals(owner: service.owner),
        const Stream.empty(),
      );
      unawaited(model.open('request:${r.id}'));
      await settle(
        t,
        () => !model.loading && !model.reading && model.detail != null,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: GrantHistoryPage(
              controller: model,
              onRecord: (_) {},
              onRequest: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(model.detail!.summary.operationCount, 1);
      expect(find.textContaining('SYNTHETIC'), findsNothing);
      final revoke = find.byKey(const ValueKey('grant-revoke'));
      await t.ensureVisible(revoke);
      await t.tap(revoke);
      await settle(
        t,
        () =>
            !model.frozen &&
            !model.loading &&
            !model.reading &&
            model.detail?.summary.state == WorkspaceGrantState.revoked,
      );
      expect(model.decisionFailure, isNull);
      await expectLater(
        service.agent.read(bearer, field),
        throwsA(isA<core.AccessFailure>()),
      );
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
