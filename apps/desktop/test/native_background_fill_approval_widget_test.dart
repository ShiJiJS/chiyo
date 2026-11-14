import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'support/online_ui_harness.dart';

import '../../../packages/info_core/test_support/native_fill.dart'
    show nativeTargetFixture;

void main() {
  for (final mixed in [false, true]) {
    testWidgets(
      'native approval and history display the exact App window field and setter boundary (mixed: $mixed)',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = core.InformationService(
          repository: core.MemoryInformationRepository(),
        );
        addTearDown(service.close);
        const secret = 'NEVER-RENDER-NATIVE-PASSWORD';
        final c = await service.owner.createStringCredential(
          name: '合成原生密码',
          publicPurpose: '',
          secret: secret,
        );
        await service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'password',
          discoverable: true,
        );
        final session = service.agent.openSession('合成原生审批');
        final target = {
          ...nativeTargetFixture(controlKind: 'macos_ax_password'),
          'appName': 'Chiyo Synthetic Native Receiver',
          'windowTitle': 'Synthetic native login',
          'fieldLabel': 'Password [AXIdentifier=loginPassword]',
        };
        final request = await service.agent.requestCredentialBatch(
          session,
          'A' * 22,
          core.CredentialBatchInput.fromJson({
            'protocolVersion': 3,
            'purpose': '合成后台填写验收',
            'items': [
              {
                'credentialId': c.id,
                'destination': {'via': 'native', 'target': target},
              },
              if (mixed)
                {
                  'credentialId': c.id,
                  'destination': {
                    'via': 'ego',
                    'target': {
                      'provider': 'ego',
                      'instanceId': 'synthetic-browser',
                      'space': 7,
                      'pageId': 'p1',
                      'url': 'https://synthetic.test/login',
                      'form': '#login',
                      'field': '#password',
                      'structureDigest': 'b' * 64,
                    },
                  },
                },
            ],
          }),
          operationId: 'native-app-review',
        );
        final source = OwnerWorkspaceApprovals(owner: service.owner);
        final controller = ApprovalsController(source, const Stream.empty());
        addTearDown(controller.dispose);
        await controller.load();
        final local = await source.read(request.id);
        final remote = approvalDetailFromJson(
          approvalDetailToJson(local, version: 5),
        );
        expect(remote.scopes.first.label, local.scopes.first.label);
        expect(
          jsonEncode(approvalDetailToJson(remote, version: 5)),
          isNot(contains(secret)),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: zhiyuTheme(Brightness.light),
            home: Scaffold(
              body: ApprovalsPage(controller: controller, onRecord: (_) {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final description in [
          '原生后台填写',
          'Chiyo Synthetic Native Receiver',
          'Synthetic native login',
          'AXIdentifier=loginPassword',
          '/Applications/Synthetic.app/',
          '不代表登录或应用业务已成功',
          '知予不主动切换窗口或焦点',
          '批准本身不输入',
        ]) {
          expect(find.textContaining(description), findsWidgets);
        }
        expect(find.textContaining(secret), findsNothing);
        final approve = find.byKey(const ValueKey('approval-approve'));
        await tester.ensureVisible(approve);
        await tester.tap(approve);
        await tester.pumpAndSettle();
        expect(
          service.owner.credentialBatches.single.items.first.decision,
          core.CredentialBatchItemDecision.approved,
        );
        expect(service.owner.credentialBatchOperations, isEmpty);

        await OnlineUiHarness(tester).resolve(() async {
          final claim = await service.agent.beginCredentialBatchOperation(
            session,
            'A' * 22,
            request.id,
            operationId: 'native-sent-record',
          );
          await service.agent.claimCredentialBatchMaterials(
            'A' * 22,
            claim.privateProof!,
            {for (final item in request.items) item.id: item.destination},
          );
          await service.agent.authorizeCredentialBatchInput(
            'A' * 22,
            claim.privateProof!,
          );
          await service.agent.finishCredentialBatchOperation(
            'A' * 22,
            claim.privateProof!,
            core.CredentialBatchOperationState.filled,
            itemResults: {'b1': 'sent', if (mixed) 'b2': 'filled'},
          );
          await controller.open(request.id);
        });
        await tester.pumpAndSettle();
        expect(find.text('已向所选控件送入密码'), findsOneWidget);
        expect(find.text('已填写'), findsNothing);
        expect(find.textContaining(secret), findsNothing);
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
