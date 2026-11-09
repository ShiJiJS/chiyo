@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/workspace/remote_workspace_hosts.dart';
import 'package:info_desktop/workspace/host_import_controller.dart';
import 'package:info_desktop/workspace/host_mutation.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import '../../../packages/info_core/test/fixtures/ssh_session_fixture.dart'
    show knownHostBytes;

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'real remote host import/revoke reply loss freezes the original UI command until the exact receipt is known',
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
        final source = RemoteWorkspaceHosts(client, changed: () {});
        final imports = HostImportController(source);
        final mutation = HostMutation(source);
        try {
          proxy.dropNextPath = '/v1/owner/ssh-hosts/inputs';
          expect(
            await imports.pick(
              () => source.stage('synthetic-known_hosts', knownHostBytes()),
            ),
            true,
          );
          expect(imports.preview, isNotNull);
          expect(proxy.requests['POST /v1/owner/ssh-hosts/inputs'], 1);
          expect(f.runtime.service.owner.sshKnownHosts, isNull);
          proxy.dropNextPath = '/v1/owner/ssh-hosts/imports';
          await imports.submit();
          expect(imports.uncertain, true);
          expect(imports.frozen, true);
          expect(f.runtime.service.owner.sshKnownHosts, isNotNull);
          proxy.failGetPrefix = '/v1/owner/ssh-hosts/import-operations/';
          await imports.reconcile();
          expect(imports.uncertain, true);
          await imports.submit();
          expect(proxy.requests['POST /v1/owner/ssh-hosts/imports'], 1);
          proxy.failGetPrefix = null;
          await imports.reconcile();
          expect(imports.result, isNotNull);
          expect(imports.uncertain, false);
          final snapshotId = f.runtime.service.owner.sshKnownHosts!.id;
          final seen = (await source.load()).single;
          proxy.dropNextPath = '/v1/owner/ssh-hosts/changes';
          expect(
            await mutation.submit(seen, WorkspaceHostAction.revoke),
            isNull,
          );
          expect(mutation.uncertain, true);
          expect(
            (await source.load()).single.state,
            WorkspaceHostState.revoked,
          );
          expect(f.runtime.service.owner.sshKnownHosts!.id, isNot(snapshotId));
          proxy.failGetPrefix = '/v1/owner/ssh-hosts/operations/';
          await mutation.reconcile();
          expect(mutation.uncertain, true);
          expect(
            await mutation.submit(seen, WorkspaceHostAction.revoke),
            isNull,
          );
          expect(proxy.requests['POST /v1/owner/ssh-hosts/changes'], 1);
          proxy.failGetPrefix = null;
          await f.reopen();
          final recovered = await mutation.reconcile();
          expect(recovered!.action, WorkspaceHostAction.revoke);
          expect(mutation.uncertain, false);
          expect(proxy.requests['POST /v1/owner/ssh-hosts/changes'], 1);
          expect(
            (await source.read(seen.target)).state,
            WorkspaceHostState.revoked,
          );
        } finally {
          imports.dispose();
          mutation.dispose();
          await source.dispose();
          client.close();
          await proxy.close();
          await f.dispose();
        }
      }, _RealHttp());
    },
  );
}
