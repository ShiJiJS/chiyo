import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class RealHttp extends HttpOverrides {}

void main() {
  test(
    'HTTPS memory browsing, frozen drafts, delta deletion, failed pulls and restart',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp('chiyo-cache-test-');
        final cert = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(cert.certificate)
          ..usePrivateKey(cert.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(cert.ca);
        await initializeServerSecrets('${root.path}/secrets');
        final keys = MountedDatabaseKeyStore(
          '${root.path}/secrets/database.key',
        );
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        late EncryptedInformationRepository repo;
        late core.OnlineInformationRuntime runtime;
        late OnlineServer server;
        Future<void> open({int port = 0}) async {
          repo = await EncryptedInformationRepository.openOnline(
            '${root.path}/data',
            keys,
          );
          runtime = await core.OnlineInformationRuntime.open(repository: repo);
          server = await OnlineServer.start(
            runtime: runtime,
            devices: AgentDeviceRegistry(repo),
            tls: tls,
            ownerToken: token,
            serverId: 'synthetic-cache-server',
            port: port,
          );
        }

        await open();
        var serverPort = server.port;
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        var requests = 0;
        var fail = false;
        Completer<void>? gate;
        proxy.listen((r) async {
          requests++;
          if (gate != null) await gate.future;
          if (fail) {
            r.response.headers.set(
              'x-chiyo-server-id',
              'synthetic-cache-server',
            );
            r.response.statusCode = 503;
            r.response.write('{"error":"synthetic_unavailable"}');
            await r.response.close();
            return;
          }
          final next = await upstream.openUrl(
            r.method,
            Uri.parse('https://127.0.0.1:$serverPort${r.uri}'),
          );
          for (final h in [
            'authorization',
            'content-type',
            'x-chiyo-server-id',
          ]) {
            if (r.headers.value(h) != null) {
              next.headers.set(h, r.headers.value(h)!);
            }
          }
          await next.addStream(r);
          final response = await next.close();
          r.response.statusCode = response.statusCode;
          r.response.headers.set('content-type', 'application/json');
          r.response.headers.set('x-chiyo-server-id', 'synthetic-cache-server');
          await response.pipe(r.response);
        });
        final client = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${proxy.port}'),
          token: token,
          trust: trust,
        );
        final source = RemoteWorkspaceSource(client);
        final item = await runtime.run(
          () => runtime.service.owner.createInformation('First', '', [
            const core.FieldInput('Body', '', 'first body'),
          ]),
        );
        await source.cache.synchronize();
        expect(
          (await client.request('GET', '/v1/owner/updates'))['summary'],
          containsPair('records', 1),
        );
        final version = (await repo.openServerState()).revision;
        await source.cache.synchronize();
        expect((await repo.openServerState()).revision, version);
        final controller = LibraryController(source);
        await controller.load(const WorkspaceQuery());
        final ref = controller.selection!;
        final original = controller.detail!;
        final legacy = RemoteWorkspaceSource(client);
        final beforeLegacy = requests;
        final legacyTime = Stopwatch()..start();
        for (var i = 0; i < 3; i++) {
          await legacy.loadCatalog();
          await legacy.queryRecords(const WorkspaceQuery());
          await legacy.readDetail(ref);
        }
        legacyTime.stop();
        final legacyRequests = requests - beforeLegacy;
        final beforeCached = requests;
        final cachedTime = Stopwatch()..start();
        for (var i = 0; i < 3; i++) {
          await source.loadCatalog();
          await source.queryRecords(const WorkspaceQuery());
          await source.readDetail(ref);
        }
        cachedTime.stop();
        expect(requests, beforeCached);
        expect(legacyRequests, 21);
        // ignore: avoid_print
        print(
          'Synthetic browse comparison: legacyRequests=$legacyRequests cacheRequests=0 '
          'legacyMicros=${legacyTime.elapsedMicroseconds} cacheMicros=${cachedTime.elapsedMicroseconds}; '
          'unchanged sync checkpoint writes=0',
        );

        gate = Completer<void>();
        final pull = source.cache.synchronize();
        final beforeBrowse = requests;
        await controller
            .load(const WorkspaceQuery(keyword: 'First'))
            .timeout(const Duration(milliseconds: 300));
        expect(controller.detail!.values, original.values);
        await source.readDetail(ref).timeout(const Duration(milliseconds: 300));
        expect(
          requests - beforeBrowse,
          lessThanOrEqualTo(1),
        ); // only the pending sync
        gate.complete();
        gate = null;
        await pull;
        final other = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${proxy.port}'),
          token: token,
          trust: trust,
        );
        core.InformationDraftInput edit(String body) =>
            core.InformationDraftInput(
              itemId: item.id,
              baseVersion: item.version,
              name: 'First',
              description: '',
              fields: [
                core.InformationDraftField.text(
                  'Body',
                  '',
                  body,
                  fieldId: item.fields.single.id,
                ),
              ],
            );
        await other.save('mac-save', edit('server new body'));
        await expectLater(
          client.save('windows-stale', edit('local old draft')),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'version_conflict',
            ),
          ),
        );
        await source.cache.synchronize();
        expect((await source.readDetail(ref)).version, item.version + 1);
        expect(
          original.version,
          item.version,
        ); // captured form remains unchanged
        other.close();
        final lastSuccess = source.cache.updatedAt;
        fail = true;
        await expectLater(
          source.cache.synchronize(),
          throwsA(isA<RemoteFailure>()),
        );
        expect(source.cache.updatedAt, lastSuccess);
        expect((await source.readDetail(ref)).version, item.version + 1);
        fail = false;
        await runtime.run(
          () => runtime.service.owner.deleteInformation(
            item.id,
            item.version + 1,
          ),
        );
        await source.cache.synchronize();
        expect((await source.queryRecords(const WorkspaceQuery())).total, 0);
        await server.close();
        await runtime.close();
        await repo.close();
        await open();
        serverPort = server.port;
        final newItem = await runtime.run(
          () => runtime.service.owner.createInformation('After restart', '', [
            const core.FieldInput('Text', '', 'new'),
          ]),
        );
        await source.cache.synchronize();
        expect(
          (await source.queryRecords(
            const WorkspaceQuery(),
          )).items.single.ref.id,
          newItem.id,
        );
        controller.dispose();
        await legacy.dispose();
        await source.dispose();
        await proxy.close(force: true);
        upstream.close(force: true);
        await server.close();
        await runtime.close();
        await repo.close();
        await root.delete(recursive: true);
      }, RealHttp());
    },
  );
}
