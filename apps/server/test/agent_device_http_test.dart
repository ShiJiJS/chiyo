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
  test(
    'only owner HTTP identity can enroll/list/revoke a restricted device',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-device-http-');
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final owner = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/data',
        MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      );
      final runtime = await OnlineInformationRuntime.open(repository: repo);
      final registry = AgentDeviceRegistry(repo);
      final server = await OnlineServer.start(
        runtime: runtime,
        devices: registry,
        tls: tls,
        ownerToken: owner,
        serverId: 'device-http-synthetic',
      );
      final client = HttpClient(context: trust);
      Future<(int, Map)> call(
        String method,
        String path,
        String token, [
        Object? body,
      ]) async {
        final request = await client.openUrl(
          method,
          Uri.parse('https://127.0.0.1:${server.port}$path'),
        );
        request.headers.set('authorization', 'Bearer $token');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join()) as Map,
        );
      }

      try {
        expect(
          (await call('POST', '/v1/owner/devices', 'invalid', {
            'operationId': 'x',
            'name': 'Invalid',
          })).$1,
          401,
        );
        expect(await registry.metadata(), isEmpty);
        final created = await call('POST', '/v1/owner/devices', owner, {
          'operationId': 'create-device',
          'name': 'Synthetic CLI',
        });
        expect(created.$1, 200);
        final device = created.$2['deviceToken'] as String;
        final id = created.$2['deviceId'] as String;
        expect((await registry.authenticate(device)).id, id);
        expect(
          (await call('POST', '/v1/owner/devices', owner, {
            'operationId': 'create-device',
            'name': 'Synthetic CLI',
          })).$2,
          created.$2,
        );
        for (final route in [
          '/v1/owner/devices',
          '/v1/owner/information',
          '/v1/owner/catalog',
        ]) {
          final rejected = await call('GET', route, device);
          expect(rejected.$1, 401);
          expect(jsonEncode(rejected.$2), isNot(contains(owner)));
        }
        expect(
          (await call('POST', '/v1/owner/devices', device, {
            'operationId': 'escalation',
            'name': 'Not allowed',
          })).$1,
          401,
        );
        final listed = await call('GET', '/v1/owner/devices', owner);
        expect(listed.$1, 200);
        expect((listed.$2['devices'] as List).single['id'], id);
        expect(jsonEncode(listed.$2), isNot(contains(device.split('.').last)));
        expect(
          (await call('POST', '/v1/owner/devices/$id/revoke', owner, {
            'operationId': 'revoke-device',
          })).$1,
          200,
        );
        await expectLater(
          registry.authenticate(device),
          throwsA(isA<AccessFailure>()),
        );
      } finally {
        client.close(force: true);
        await server.close();
        await runtime.close();
        await repo.close();
      }
    },
  );
}
