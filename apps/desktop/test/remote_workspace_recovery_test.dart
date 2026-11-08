import 'package:info_server/agent_devices.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'lost save response reconciles its original receipt without a duplicate',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'chiyo-response-loss-',
        );
        final tlsFixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(tlsFixture.certificate)
          ..usePrivateKey(tlsFixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(tlsFixture.ca);
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
        final service = core.InformationService(repository: repo);
        final server = await OnlineServer.start(
          devices: AgentDeviceRegistry(repo),
          service: service,
          tls: tls,
          ownerToken: token,
          serverId: 'response-loss-synthetic',
        );
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        final serverPort = server.port;
        proxy.listen((request) async {
          try {
            final next = await upstream.openUrl(
              request.method,
              Uri.parse('https://127.0.0.1:$serverPort${request.uri.path}'),
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
            if (request.method == 'POST') {
              // The real production host has committed. Only the network response
              // is lost; there is no altered save or test bypass in the product.
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
              'response-loss-synthetic',
            );
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'server_unavailable'}));
            await request.response.close();
          }
        });
        RemoteWorkspaceSource? source;
        try {
          source = RemoteWorkspaceSource(
            await OwnerClient.connect(
              address: Uri.parse('https://127.0.0.1:${proxy.port}'),
              token: token,
              trust: trust,
            ),
          );
          final definition = await source.loadTemplate('generic');
          final draft = WorkspaceCreate(
            operationId: 'lost-save',
            typeId: 'generic',
            name: 'Synthetic lost response',
            expectedTemplateVersion: definition['templateVersion'] as String,
            expectedTemplateDigest: definition['packageDigest'] as String,
            values: {'body': 'synthetic private content'},
          );
          await expectLater(
            source.createRecord(draft),
            throwsA(
              isA<WorkspaceFailure>().having(
                (e) => e.code,
                'code',
                'unknown_outcome',
              ),
            ),
          );
          expect(service.owner.information, hasLength(1));
          final receipt = await source.recordOperationReceipt('lost-save');
          expect(receipt!.result.ref.id, service.owner.information.single.id);
          expect(receipt.intent.kind, WorkspaceOperationKind.create);
          expect(receipt.intent.typeId, 'generic');
          expect(
            await source.recordOperationReceipt('never-submitted'),
            isNull,
          );
          await server.close();
          // A failed lookup must not be reported as "definitely not saved".
          await expectLater(
            source.recordOperationReceipt('lost-save'),
            throwsA(isA<WorkspaceFailure>()),
          );
        } finally {
          await source?.dispose();
          await proxy.close(force: true);
          upstream.close(force: true);
          await server.close();
          await service.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
