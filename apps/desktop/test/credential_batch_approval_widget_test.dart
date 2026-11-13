import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/workspace_approvals.dart';

void main() {
  testWidgets(
    'one App request shows each exact destination and approves only selected credentials',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = core.InformationService(
        repository: core.MemoryInformationRepository(),
      );
      final cs = <core.ManagedCredential>[];
      for (var i = 0; i < 2; i++) {
        final c = await service.owner.createStringCredential(
          name: '合成服务密码$i',
          publicPurpose: '',
          secret: 'NEVER-RENDER-MATERIAL',
        );
        cs.add(
          await service.owner.updateCredentialMetadata(
            c.id,
            c.revision,
            name: c.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'password',
            discoverable: true,
          ),
        );
      }
      final session = service.agent.openSession('合成聊天');
      final request = await service.agent.requestCredentialBatch(
        session,
        'A' * 22,
        core.CredentialBatchInput.fromJson({
          'protocolVersion': 3,
          'purpose': '登录两个合成服务',
          'agentName': 'Trial Agent',
          'externalChatId': 'trial-chat',
          'submissionVersion': 1,
          'items': [
            for (final (index, c) in cs.indexed)
              {
                'credentialId': c.id,
                'destination': {
                  'via': 'ego',
                  'target': {
                    'provider': 'ego',
                    'space': 7,
                    'pageId': 'p${index + 1}',
                    'instanceId': 'synthetic-browser',
                    'url': 'https://synthetic$index.test/login',
                    'form': '#login',
                    'field': '#password',
                    'structureDigest': 'a' * 64,
                  },
                },
              },
          ],
        }),
        operationId: 'submit-widget',
      );
      final controller = ApprovalsController(
        OwnerWorkspaceApprovals(owner: service.owner),
        const Stream.empty(),
      );
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ApprovalsPage(controller: controller, onRecord: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2份凭据使用申请'), findsWidgets);
      expect(
        find.textContaining('https://synthetic0.test/login'),
        findsOneWidget,
      );
      expect(
        find.textContaining('https://synthetic1.test/login'),
        findsOneWidget,
      );
      expect(find.textContaining('NEVER-RENDER-MATERIAL'), findsNothing);
      expect(controller.detail!.credentialBatch, true);
      controller.toggle('b2');
      await controller.decide(WorkspaceApprovalAction.approve);
      await tester.pumpAndSettle();
      final result = service.agent.credentialBatchStatus(
        session,
        'A' * 22,
        request.id,
      );
      expect(result['status'], 'partially_approved');
      expect((result['items'] as List).first['decision'], 'approved');
      expect((result['items'] as List).last['decision'], 'denied');
      expect(find.textContaining('NEVER-RENDER-MATERIAL'), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await service.close();
    },
  );
}
