import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/workspace_approvals.dart';
import '../../../packages/info_core/test/fixtures/ssh_session_fixture.dart'
    show knownHostBytes;

void main() {
  for (final use in ['login', 'sudo']) {
    test(
      'SSH $use approval preserves scope and session lifetime over wire',
      () async {
        final service = core.InformationService(
          repository: core.MemoryInformationRepository(),
        );
        addTearDown(service.close);
        var c = await service.owner.createStringCredential(
          name: '合成SSH密码',
          publicPurpose: 'test',
          secret: 'NEVER-RENDER-SSH-SECRET',
        );
        c = await service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: 'test',
          privateNote: '',
          suggestedBinding: '',
          discoverable: true,
        );
        await service.owner.configureSshKnownHosts('fixture', knownHostBytes());
        final session = service.agent.openSession('Synthetic SSH');
        final request = await service.agent.requestCredentialBatch(
          session,
          'A' * 22,
          core.CredentialBatchInput.fromJson({
            'protocolVersion': 3,
            'purpose': '检查合成服务器',
            'items': [
              {
                'credentialId': c.id,
                'destination': {
                  'via': 'ssh',
                  'target': core.SshSessionTarget(
                    host: 'example.test',
                    port: 2222,
                    user: 'fixture',
                    authentication: 'password',
                    credentialUse: use,
                    validity: 'session',
                  ).toJson(),
                },
              },
            ],
          }),
          operationId: 'request',
        );
        final owner = OwnerWorkspaceApprovals(owner: service.owner);
        final detail = await owner.read(request.id);
        expect(detail.sshSession, isTrue);
        expect(detail.supportsSessionValidity, isTrue);
        expect(
          detail.scopes.single.label,
          contains('fixture@example.test:2222'),
        );
        expect(
          detail.scopes.single.label,
          contains(use == 'sudo' ? 'sudo 认证' : '登录并持续执行命令'),
        );
        expect(detail.scopes.single.label, isNot(contains('NEVER-RENDER')));
        expect(
          () => approvalDetailToJson(detail, version: 5),
          throwsA(anything),
        );
        final wire = approvalDetailFromJson(
          Map<String, dynamic>.from(approvalDetailToJson(detail, version: 6)),
        );
        expect(wire.sshSession, isTrue);
        expect(wire.sshTarget!.host, 'example.test');
        expect(wire.sshTarget!.port, 2222);
        expect(wire.sshTarget!.user, 'fixture');
        expect(wire.sshTarget!.credentialUse, use);
        expect(wire.supportsSessionValidity, isTrue);
        await owner.change(
          WorkspaceApprovalChange(
            operationId: 'approve',
            requestId: request.id,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: [detail.scopes.single.id],
            credentialMinutes: null,
          ),
        );
        final approved = await owner.read(request.id);
        expect(approved.credentialSessionBound, isTrue);
        expect(approved.credentialExpiresAt, isNull);
        expect(
          approvalDetailFromJson(
            Map<String, dynamic>.from(
              approvalDetailToJson(approved, version: 6),
            ),
          ).credentialSessionBound,
          isTrue,
        );
        expect(
          service.agent.checkSshSessionGrant(
            session,
            'A' * 22,
            request.id,
          )['status'],
          'ok',
        );
        if (use == 'login') {
          final context = core.SshSessionOperationContext(
            kind: 'run',
            sessionId: 'ssh-synthetic',
            runId: 'run-synthetic',
            digest: 'sha256:${'a' * 64}',
            byteLength: 10,
          );
          final run = await service.agent.beginCredentialBatchOperation(
            session,
            'A' * 22,
            request.id,
            operationId: 'run-synthetic',
            sshContext: context,
          );
          final before = (await owner.read(request.id)).batchOperations.single;
          await service.agent.authorizeCredentialBatchInput(
            'A' * 22,
            run.privateProof!,
          );
          await service.agent.finishCredentialBatchOperation(
            'A' * 22,
            run.privateProof!,
            core.CredentialBatchOperationState.filled,
            itemResults: {'b1': 'sent'},
          );
          final observed = await owner.read(request.id);
          final encoded = Map<String, dynamic>.from(
            approvalDetailToJson(observed, version: 6),
          );
          final decoded = approvalDetailFromJson(encoded);
          final operation = decoded.batchOperations.single;
          expect(operation.sshContext!.toJson(), context.toJson());
          expect(operation.updates(before), isTrue);
          expect(operation.summaryLabel, '命令已发送');
          expect(operation.itemResultLabel('sent'), '命令已发送');
          expect(operation.operationLabel, '发送远程命令');
          expect(
            encoded.toString(),
            isNot(contains('NEVER-RENDER-SSH-SECRET')),
          );
          expect(
            decoded.withBatchOperation(operation).sshTarget!.host,
            'example.test',
          );
          final changed = Map<String, dynamic>.from(operation.toJson());
          changed['sshContext'] = {
            ...context.toJson(),
            'sessionId': 'another-connection',
          };
          expect(
            WorkspaceCredentialBatchOperation.fromJson(
              changed,
            ).updates(operation),
            isFalse,
          );
          changed['sshContext'] = {
            ...context.toJson(),
            'text': 'must-not-cross-transport',
          };
          expect(
            () => WorkspaceCredentialBatchOperation.fromJson(changed),
            throwsA(anything),
          );
          encoded['sshTarget'] = null;
          expect(() => approvalDetailFromJson(encoded), throwsFormatException);
        }
        await owner.change(
          WorkspaceApprovalChange(
            operationId: 'revoke',
            requestId: request.id,
            reviewToken: approved.reviewToken,
            action: WorkspaceApprovalAction.revoke,
          ),
        );
        final revoked = await owner.read(request.id);
        expect(revoked.credentialSessionBound, isTrue);
        expect(
          () =>
              service.agent.checkSshSessionGrant(session, 'A' * 22, request.id),
          throwsA(anything),
        );
      },
    );
  }
}
