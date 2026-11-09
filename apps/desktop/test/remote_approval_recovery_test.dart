@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/remote_workspace_approvals.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'a lost approval reply freezes its original command and reconciles without granting twice',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'chiyo-approval-response-loss-',
        );
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        await initializeServerSecrets('${root.path}/secrets');
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        final repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        final runtime = await core.OnlineInformationRuntime.open(
          repository: repo,
        );
        final server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'approval-response-loss-synthetic',
        );
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        final port = server.port;
        proxy.listen((request) async {
          try {
            final next = await upstream.openUrl(
              request.method,
              Uri.parse('https://127.0.0.1:$port${request.uri.path}'),
            );
            for (final name in [
              'authorization',
              'content-type',
              'x-chiyo-server-id',
            ]) {
              final value = request.headers.value(name);
              if (value != null) next.headers.set(name, value);
            }
            await next.addStream(request);
            final response = await next.close();
            final bytes = await response.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            if (request.uri.path == '/v1/owner/approvals/decisions') {
              // The genuine owner path has committed; discard only its response.
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
            request.response.statusCode = response.statusCode;
            request.response.headers.set(
              'x-chiyo-server-id',
              response.headers.value('x-chiyo-server-id')!,
            );
            request.response.headers.contentType = ContentType.json;
            request.response.add(bytes);
            await request.response.close();
          } on Object {
            request.response.statusCode = 503;
            request.response.headers.set(
              'x-chiyo-server-id',
              'approval-response-loss-synthetic',
            );
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'server_unavailable'}));
            await request.response.close();
          }
        });
        OwnerClient? client;
        ApprovalsController? controller;
        try {
          final item = await runtime.run(
            () => runtime.service.owner.createInformation('Synthetic', '', [
              const core.FieldInput('Body', '', 'PRIVATE'),
            ]),
          );
          final session = await runtime.run(
            () =>
                runtime.service.agent.openSession('Synthetic lost-reply chat'),
          );
          final requested = await runtime.run(
            () => runtime.service.agent.request(session, 'Synthetic read', [
              core.FieldRef(item.id, item.fields.single.id),
            ]),
          );
          client = await OwnerClient.connect(
            address: Uri.parse('https://127.0.0.1:${proxy.port}'),
            token: token,
            trust: trust,
          );
          final source = RemoteWorkspaceApprovals(client, onChanged: () {});
          final model = controller = ApprovalsController(
            source,
            const Stream.empty(),
          );
          await model.load();
          expect(model.detail!.request.id, requested.id);
          await model.decide(WorkspaceApprovalAction.approve);
          expect(model.uncertain, isTrue);
          expect(model.frozen, isTrue);
          expect(repo.grantHistory, hasLength(1));
          final grantId = repo.grantHistory.single.id;
          await model.decide(WorkspaceApprovalAction.approve);
          expect(repo.grantHistory.single.id, grantId);
          await model.reconcile();
          expect(model.uncertain, isFalse);
          expect(model.writeFailure, isNull);
          expect(model.detail!.request.state, WorkspaceApprovalState.approved);
          expect(repo.grantHistory.single.id, grantId);
          final grant = await runtime.run(
            () => runtime.service.agent.claim(session, requested.id),
          );
          expect(
            await runtime.run(
              () => runtime.service.agent.read(
                grant.token,
                core.FieldRef(item.id, item.fields.single.id),
              ),
            ),
            'PRIVATE',
          );
          expect(await source.receipt('never-submitted'), isNull);
          await server.close();
          await expectLater(
            source.receipt('never-submitted'),
            throwsA(isA<WorkspaceFailure>()),
          );
        } finally {
          controller?.dispose();
          client?.close();
          await proxy.close(force: true);
          upstream.close(force: true);
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
