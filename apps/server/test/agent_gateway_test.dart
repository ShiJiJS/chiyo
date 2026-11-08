import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/agent_gateway.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

class DelayedReadProtocol extends AgentProtocol {
  DelayedReadProtocol(super.agent);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Map<String, Object?>> dispatch(
    String path,
    Map<String, dynamic> body,
  ) async {
    final result = await super.dispatch(path, body);
    if (path == '/read') {
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  late Directory root;
  late EncryptedInformationRepository repo;
  late InformationService service;
  late OnlineInformationRuntime runtime;
  late AgentDeviceRegistry devices;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chiyo-agent-gateway-');
    await initializeServerSecrets('${root.path}/secrets');
    repo = await EncryptedInformationRepository.openOnline(
      '${root.path}/data',
      MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
    );
    runtime = await OnlineInformationRuntime.open(repository: repo);
    service = runtime.service;
    devices = AgentDeviceRegistry(repo);
  });
  tearDown(() async {
    await runtime.close();
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'HTTPS Agent requests use only approved fields on the original device',
    () async {
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final ownerToken = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      var server = await OnlineServer.start(
        runtime: runtime,
        devices: devices,
        tls: tls,
        ownerToken: ownerToken,
        serverId: 'synthetic-agent-gateway',
      );
      final client = HttpClient(context: trust);
      addTearDown(() async {
        client.close(force: true);
        await server.close();
      });
      Future<(int, Map<String, dynamic>)> call(
        String token,
        String path,
        Map<String, Object?> body, {
        String? origin,
        String? serverId,
      }) async {
        final request = await client.postUrl(
          Uri.parse('https://127.0.0.1:${server.port}$path'),
        );
        request.headers.set('authorization', 'Bearer $token');
        if (origin != null) request.headers.set('origin', origin);
        if (serverId != null)
          request.headers.set('x-chiyo-server-id', serverId);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
        );
      }

      final item = await service.owner
          .createInformation('Synthetic server', 'Public purpose', [
            const FieldInput(
              'Address',
              'Public field description',
              'PRIVATE_SELECTED',
            ),
            const FieldInput('Other', '', 'PRIVATE_UNSELECTED'),
          ]);
      final a = await devices.enroll('a', 'Synthetic device A');
      final b = await devices.enroll('b', 'Synthetic device B');
      Future<(int, Map<String, dynamic>)> agent(
        String token,
        String path,
        Map<String, Object?> body,
      ) => call(token, '/v1/agent$path', body);
      expect((await agent(ownerToken, '/catalog', {})).$1, 401);
      expect((await agent('invalid', '/catalog', {})).$1, 401);
      expect(
        (await call(
          a.bearer,
          '/v1/agent/catalog',
          {},
          origin: 'https://untrusted.invalid',
        )).$1,
        401,
      );
      expect(
        (await call(a.bearer, '/v1/agent/session', {
          'chatLabel': 'Wrong host',
        }, serverId: 'another-host')).$1,
        409,
      );
      expect(service.owner.sessions, isEmpty);
      final catalog = await agent(a.bearer, '/catalog', {});
      expect(catalog.$1, 200);
      expect(jsonEncode(catalog.$2), contains('Public purpose'));
      expect(jsonEncode(catalog.$2), isNot(contains('PRIVATE_')));
      final capabilities = await agent(a.bearer, '/capabilities', {});
      expect(
        capabilities.$2['capabilities'],
        contains('agent-device-binding.v1'),
      );
      expect(
        capabilities.$2['capabilities'],
        contains('credential-use-reuse.v1'),
      );
      expect((await agent(a.bearer, '/approve', {})).$1, 409);
      expect(
        (await call(a.bearer, '/v1/owner/devices', {
          'operationId': 'evil',
          'name': 'evil',
        })).$1,
        401,
      );
      final opened = (await agent(a.bearer, '/session/lifecycle', {
        'chatLabel': 'Synthetic chat A',
      })).$2;
      final session = opened['sessionSecret'] as String;
      expect(
        (await agent(b.bearer, '/session/check', {
          'sessionSecret': session,
        })).$1,
        401,
      );
      expect(
        (await agent(b.bearer, '/session/end', {
          'endCapability': opened['endCapability'],
        })).$1,
        401,
      );
      final requestBody = {
        'sessionSecret': session,
        'operationId': 'request-once',
        'purpose': 'Synthetic partial read',
        'fields': [
          for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
        ],
      };
      final requested = await agent(a.bearer, '/request', requestBody);
      expect(requested.$1, 200);
      final requestId = requested.$2['requestId'] as String;
      expect((await agent(a.bearer, '/request', requestBody)).$2, requested.$2);
      expect(service.owner.requests, hasLength(1));
      final claimBody = {'sessionSecret': session, 'requestId': requestId};
      expect(
        (await agent(a.bearer, '/claim', claimBody)).$2['error'],
        'pending',
      );
      final command = InformationApprovalCommand(
        operationId: 'synthetic-approval',
        requestId: requestId,
        action: InformationApprovalAction.approve,
        reviewToken: 'a' * 64,
        commandDigest: 'b' * 64,
        fields: [FieldRef(item.id, item.fields.first.id)],
        itemVersions: {item.id: item.version},
      );
      await runtime.run(() => service.owner.decideInformationRequest(command));
      await runtime.run(() => service.owner.decideInformationRequest(command));
      final grant = (await agent(a.bearer, '/claim', claimBody)).$2;
      expect(grant['status'], 'ok');
      expect((await agent(a.bearer, '/claim', claimBody)).$2, grant);
      final readBody = {
        'token': grant['token'],
        'itemId': item.id,
        'fieldId': item.fields.first.id,
      };
      expect((await agent(b.bearer, '/read', readBody)).$1, 401);
      expect(
        (await agent(a.bearer, '/read', {
          ...readBody,
          'fieldId': item.fields.last.id,
        })).$1,
        401,
      );
      expect(
        (await agent(a.bearer, '/read', readBody)).$2['value'],
        'PRIVATE_SELECTED',
      );
      // Recreate every host object over the same encrypted volume. No in-memory
      // service, device registry or gateway can account for the resumed proof.
      await server.close();
      await runtime.close();
      await repo.close();
      repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/data',
        MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      );
      runtime = await OnlineInformationRuntime.open(repository: repo);
      service = runtime.service;
      devices = AgentDeviceRegistry(repo);
      server = await OnlineServer.start(
        runtime: runtime,
        devices: devices,
        tls: tls,
        ownerToken: ownerToken,
        serverId: 'synthetic-agent-gateway',
      );
      expect((await agent(a.bearer, '/claim', claimBody)).$2, grant);
      expect(
        (await agent(a.bearer, '/read', readBody)).$2['value'],
        'PRIVATE_SELECTED',
      );
      expect(
        (await agent(a.bearer, '/session/end', {
          'endCapability': opened['endCapability'],
        })).$1,
        200,
      );
      expect((await agent(a.bearer, '/read', readBody)).$1, 401);
      await devices.revoke('revoke-a', a.identity.id);
      expect((await agent(a.bearer, '/catalog', {})).$1, 401);
      expect((await agent(b.bearer, '/catalog', {})).$1, 200);
      expect(repo.grantHistory, hasLength(1));
    },
  );

  test(
    'device revocation while a read is in flight withholds its result',
    () async {
      final item = await service.owner.createInformation('Synthetic', '', [
        const FieldInput('Body', '', 'PRIVATE'),
      ]);
      final protocol = DelayedReadProtocol(service.agent);
      final gateway = AgentGateway(protocol, devices);
      final a = await devices.enroll('a', 'Synthetic');
      final opened = await gateway.dispatch(a.bearer, '/session/lifecycle', {
        'chatLabel': 'Synthetic',
      });
      final request = await gateway.dispatch(a.bearer, '/request', {
        'sessionSecret': opened['sessionSecret'],
        'purpose': 'Synthetic read',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      });
      await service.owner.decideInformationRequest(
        InformationApprovalCommand(
          operationId: 'approval',
          requestId: request['requestId'] as String,
          action: InformationApprovalAction.approve,
          reviewToken: 'a' * 64,
          commandDigest: 'b' * 64,
          fields: [FieldRef(item.id, item.fields.single.id)],
          itemVersions: {item.id: item.version},
        ),
      );
      final grant = await gateway.dispatch(a.bearer, '/claim', {
        'sessionSecret': opened['sessionSecret'],
        'requestId': request['requestId'],
      });
      final reading = gateway.dispatch(a.bearer, '/read', {
        'token': grant['token'],
        'itemId': item.id,
        'fieldId': item.fields.single.id,
      });
      final rejected = expectLater(
        reading,
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'unauthorized',
          ),
        ),
      );
      await protocol.entered.future;
      await devices.revoke('revoke-during-read', a.identity.id);
      protocol.release.complete();
      await rejected;
    },
  );
}
