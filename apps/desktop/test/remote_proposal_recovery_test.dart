import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/remote_workspace_proposals.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/agent_connection.dart';
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
    'lost whole-proposal response freezes resubmission; failed receipt reads are not absence',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'chiyo-proposal-response-loss-',
        );
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
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
        const serverId = 'proposal-response-loss-synthetic';
        final server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
        );
        final direct = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
        final device = await direct.request('POST', '/v1/owner/devices', {
          'operationId': 'enroll',
          'name': 'Synthetic CLI',
        });
        final cli = AgentClient.remote(
          AgentConnectionProfile(
            address: direct.address,
            deviceToken: device['deviceToken'] as String,
            serverId: serverId,
            certificate: await File(fixture.ca).readAsString(),
          ),
        );
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        var decisions = 0, failReceipts = false;
        proxy.listen((request) async {
          try {
            if (failReceipts &&
                request.uri.path.contains('/proposals/operations/')) {
              request.response.statusCode = 503;
              request.response.headers.set('x-chiyo-server-id', serverId);
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({'error': 'server_unavailable'}),
              );
              await request.response.close();
              return;
            }
            final next = await upstream.openUrl(
              request.method,
              direct.address.resolve(request.uri.path),
            );
            for (final key in [
              'authorization',
              'content-type',
              'x-chiyo-server-id',
            ]) {
              final value = request.headers.value(key);
              if (value != null) next.headers.set(key, value);
            }
            await next.addStream(request);
            final response = await next.close();
            final bytes = await response.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            if (request.uri.path == '/v1/owner/proposals/decisions') {
              decisions++;
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
            try {
              request.response.statusCode = 503;
              await request.response.close();
            } on Object {
              /* disconnected */
            }
          }
        });
        OwnerClient? owner;
        ProposalsController? model;
        try {
          await cli.execute({
            'command': 'session',
            'chatLabel': 'Synthetic lost proposal response',
          });
          final template =
              (await cli.execute({
                    'command': 'template-read',
                    'templateId': 'document',
                  }))['template']
                  as Map;
          final example =
              ((template['submissionExample'] as Map)['items'] as List).single
                  as Map;
          final pending = await cli.execute({
            'command': 'import-submit',
            'operationId': 'lost-response-pair',
            'items': [
              {
                ...Map<String, Object?>.from(example),
                'key': 'a',
                'name': 'Synthetic first',
              },
              {
                ...Map<String, Object?>.from(example),
                'key': 'b',
                'name': 'Synthetic second',
              },
            ],
          });
          expect(pending['status'], 'pending');
          owner = await OwnerClient.connect(
            address: Uri.parse('https://127.0.0.1:${proxy.port}'),
            token: token,
            trust: trust,
          );
          model = ProposalsController(
            RemoteWorkspaceProposals(owner, changed: () {}),
            const Stream.empty(),
          );
          await model.open(pending['proposalId'] as String);
          expect(model.canConfirm, true);
          await model.decide(WorkspaceProposalAction.confirm);
          expect(model.uncertain, true);
          expect(model.frozen, true);
          expect(decisions, 1);
          expect(await direct.information(), hasLength(2));
          await model.decide(WorkspaceProposalAction.confirm);
          expect(decisions, 1);
          failReceipts = true;
          await model.reconcile();
          expect(model.uncertain, true);
          expect(model.frozen, true);
          await model.decide(WorkspaceProposalAction.confirm);
          expect(decisions, 1);
          failReceipts = false;
          await model.reconcile();
          expect(model.uncertain, false);
          expect(model.writeFailure, isNull);
          expect(
            model.detail!.summary.status,
            WorkspaceProposalStatus.completed,
          );
          final rows = await direct.information();
          expect(rows, hasLength(2));
          expect(rows.every((i) => i.version == 1), true);
          expect(decisions, 1);
        } finally {
          model?.dispose();
          owner?.close();
          cli.close();
          direct.close();
          upstream.close(force: true);
          await proxy.close(force: true);
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
