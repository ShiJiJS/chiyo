import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'remote CLI requests separate plaintext permission and owner reads saved string without approval',
    () async {
      final f = await DeviceCredentialFixture.create();
      final client = AgentClient.remote(
        f.profiles.first,
        requireSubmissionMetadata: true,
        sourceAgent: 'Synthetic reveal agent',
        externalChatId: 'synthetic-reveal-chat',
      );
      addTearDown(() async {
        client.close();
        await f.dispose();
      });
      final c = await f.runtime.run(() async {
        final c = await f.runtime.service.owner.createStringCredential(
          name: 'Synthetic saved',
          publicPurpose: '',
          secret: 'SYNTHETIC_REMOTE_REVEAL',
        );
        return f.runtime.service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'TOKEN',
          discoverable: true,
        );
      });
      final ownerValue = await f.owner.request(
        'POST',
        '/v1/owner/credentials/${c.id}/reveal',
        {'materialVersion': c.version},
      );
      expect(ownerValue['secret'], 'SYNTHETIC_REMOTE_REVEAL');
      expect(f.runtime.service.owner.credentialUseRequests, isEmpty);
      await client.openLifecycleSession('Synthetic reveal chat');
      final requested = await client.execute({
        'command': 'request-reveal',
        'protocolVersion': 2,
        'credentialId': c.id,
        'version': c.version,
        'purpose': 'Synthetic fallback',
        'fallbackReason': 'No verified focused control or compatible program',
      });
      expect(requested['status'], 'pending', reason: jsonEncode(requested));
      final id = requested['requestId'] as String;
      final detail = approvalDetailFromJson(
        await f.owner.request('GET', '/v1/owner/approvals/details/$id'),
      );
      expect(detail.request.title, 'AI 读取凭据原文申请');
      expect(detail.credential!.delivery, WorkspaceCredentialDelivery.reveal);
      expect(detail.scopes.single.label, contains('原文会进入当前聊天'));
      expect(
        jsonEncode(
          await f.owner.request('GET', '/v1/owner/approvals/details/$id'),
        ),
        isNot(contains('SYNTHETIC_REMOTE_REVEAL')),
      );
      await f.owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'reveal-approve',
            requestId: id,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: detail.scopes.map((s) => s.id),
            credentialMinutes: 15,
          ),
        ),
      );
      final result = await client.execute({
        'command': 'read-reveal',
        'protocolVersion': 2,
        'requestId': id,
        'operationId': 'reveal-read',
      });
      expect(
        result['secret'],
        'SYNTHETIC_REMOTE_REVEAL',
        reason: jsonEncode(result),
      );
      final history = await f.owner.request(
        'GET',
        '/v1/owner/credentials/${c.id}/history',
      );
      expect(jsonEncode(history), contains('AI 读取凭据原文'));
      expect(jsonEncode(history), isNot(contains('SYNTHETIC_REMOTE_REVEAL')));
    },
  );
}
