@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/workspace/remote_workspace_approvals.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'normal credential approval and revoke reconcile their original lost replies after encrypted server restart',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        final client = await OwnerClient.connect(
          address: proxy.address,
          token: f.token,
          trust: f.trust,
        );
        final source = RemoteWorkspaceApprovals(client, onChanged: () {});
        final model = ApprovalsController(source, const Stream.empty());
        try {
          // Reuse the isolated fixture's credential/chat, not a personal tool or
          // executable. Actual native execution is covered by online_ssh_widget.
          final setup = await f.tokenOperation();
          final input = CredentialUseInput.fromJson(
            f.runtime.service.owner.credentialUseRequests.single
                .toRequestInputJson(),
          );
          final session = setup['sessionSecret'] as String;
          final request = await f.runtime.run(
            () => f.runtime.service.agent.requestDeviceCredentialUse(
              f.profiles.first.deviceToken.split('.').first,
              session,
              input,
              DeviceCredentialLaunch.fromPrivateJson(
                (setup['deviceLaunch'] as Map).cast<String, dynamic>(),
              ),
            ),
          );
          await model.load();
          expect(model.detail!.request.id, request.id);
          expect(model.detail!.credential, isNotNull);
          model.lifetime(30, credential: true);
          DateTime? deadline;
          for (final action in [
            WorkspaceApprovalAction.approve,
            WorkspaceApprovalAction.revoke,
          ]) {
            proxy.dropNextPath = '/v1/owner/approvals/decisions';
            final writes =
                proxy.requests['POST /v1/owner/approvals/decisions'] ?? 0;
            await model.decide(action);
            expect(model.uncertain, true);
            expect(model.frozen, true);
            final saved = f.runtime.service.owner.credentialUseRequests
                .singleWhere((r) => r.id == request.id);
            if (action == WorkspaceApprovalAction.approve) {
              expect(saved.credentialApproved, true);
              deadline = saved.credentialExpiresAt;
              expect(deadline, isNotNull);
            } else {
              expect(saved.invalidatedCode, 'grant_revoked');
            }
            proxy.failGetPrefix = '/v1/owner/approvals/operations/';
            await model.reconcile();
            expect(model.uncertain, true);
            await model.decide(action);
            expect(
              proxy.requests['POST /v1/owner/approvals/decisions'],
              writes + 1,
            );
            await f.reopen();
            proxy.failGetPrefix = null;
            await model.reconcile();
            expect(model.uncertain, false);
            expect(model.writeFailure, isNull);
            expect(model.detail!.request.id, request.id);
            final reopened = f.runtime.service.owner.credentialUseRequests
                .singleWhere((r) => r.id == request.id);
            expect(reopened.credentialExpiresAt, deadline);
            expect(
              proxy.requests['POST /v1/owner/approvals/decisions'],
              writes + 1,
            );
            expect(
              await f.runtime.service.owner.additionalApprovalRevision(
                request.id,
              ),
              action == WorkspaceApprovalAction.approve ? 1 : 2,
            );
            expect(
              f.runtime.service.owner.credentialGrantState(reopened),
              action == WorkspaceApprovalAction.approve
                  ? 'available'
                  : 'revoked',
            );
          }
        } finally {
          model.dispose();
          client.close();
          await proxy.close();
          await f.dispose();
        }
      }, _RealHttp());
    },
  );
}
