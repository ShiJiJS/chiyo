import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test('authenticated health bypasses a held durable business queue', () async {
    final root = await Directory.systemTemp.createTemp('chiyo-health-');
    final tls = await createTlsFixture(root);
    await initializeServerSecrets('${root.path}/secrets');
    final repo = await EncryptedInformationRepository.openOnline(
      '${root.path}/data',
      MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
    );
    final runtime = await OnlineInformationRuntime.open(repository: repo);
    final token = base64Url.encode(List.filled(32, 17)).replaceAll('=', '');
    final server = await OnlineServer.start(
      devices: AgentDeviceRegistry(repo),
      runtime: runtime,
      tls: SecurityContext()
        ..useCertificateChain(tls.certificate)
        ..usePrivateKey(tls.privateKey),
      ownerToken: token,
      serverId: 'health-fixture-server-0001',
    );
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(tls.ca),
    );
    Future<int> get(
      String path, {
      String? bearer,
      String? identity,
      String? origin,
    }) async {
      final req = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}$path'),
      );
      req.headers.set('authorization', 'Bearer ${bearer ?? token}');
      if (identity != null) req.headers.set('x-chiyo-server-id', identity);
      if (origin != null) req.headers.set('origin', origin);
      final response = await req.close();
      await response.drain<void>();
      return response.statusCode;
    }

    final entered = Completer<void>(), release = Completer<void>();
    final held = runtime.run(() async {
      entered.complete();
      await release.future;
    });
    try {
      await entered.future;
      expect(
        await get('/v1/owner/health').timeout(const Duration(seconds: 2)),
        200,
      );
      expect(await get('/v1/owner/health', bearer: 'agent-not-owner'), 401);
      expect(await get('/v1/owner/health', identity: 'other-server'), 409);
      expect(
        await get('/v1/owner/health', origin: 'https://example.invalid'),
        401,
      );
      var finished = false;
      final update = get('/v1/owner/updates').then((status) {
        finished = true;
        return status;
      });
      // A second health response crosses the live HTTPS transport while the
      // update still awaits the deliberately held business transaction.
      expect(await get('/v1/owner/health'), 200);
      expect(finished, isFalse);
      release.complete();
      await held;
      expect(await update, 200);
    } finally {
      if (!release.isCompleted) release.complete();
      await held;
      client.close(force: true);
      await server.close();
      await runtime.close();
      await repo.close();
      await root.delete(recursive: true);
    }
  });
}
