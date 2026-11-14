import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'authenticated local batch transport stays gated and reports v3 errors',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final http = HttpClient();
      final token = '${'A' * 22}.${'B' * 43}';
      const libraryId = 'synthetic-library-id';
      AgentServer? server;
      addTearDown(() async {
        http.close(force: true);
        await server?.close();
        await service.close();
      });
      Future<Map<String, dynamic>> call(
        String path,
        Map<String, dynamic> body, {
        bool authorized = true,
      }) async {
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:${server!.port}$path'),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set(
          'authorization',
          'Bearer ${authorized ? token : 'invalid'}',
        );
        request.headers.set('x-chiyo-server-id', libraryId);
        request.write(jsonEncode(body));
        final response = await request.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      server = await AgentServer.start(
        service.agent,
        port: 0,
        connectionToken: token,
        libraryId: libraryId,
      );
      const base = '/credential-use/batch';
      expect(
        (await call('$base/request', {}))['errorCode'],
        'unsupported_capability',
      );
      expect(
        (await call('/capabilities', {}))['capabilities'],
        isNot(contains('credential-native-fill.v2')),
      );
      await server.close();
      server = await AgentServer.start(
        service.agent,
        port: 0,
        connectionToken: token,
        libraryId: libraryId,
        enableCredentialBatches: true,
      );
      final capabilities = (await call('/capabilities', {}))['capabilities'];
      expect(capabilities, contains('credential-native-fill.v2'));
      expect(capabilities, isNot(contains('credential-native-fill.v1')));
      final session = (await call('/session/lifecycle', {
        'chatLabel': 'Synthetic local chat',
      }))['sessionSecret'];
      final notStarted = await call('$base/operation', {
        'sessionSecret': session,
        'operationId': 'local-first-execution',
      });
      expect(notStarted, {
        'status': 'not_found',
        'operationId': 'local-first-execution',
        'protocolVersion': 3,
      });
      final c = await service.owner.createStringCredential(
        name: 'Synthetic password',
        publicPurpose: '',
        secret: 'DO-NOT-RETURN-THIS-PASSWORD',
      );
      await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'password',
        discoverable: true,
      );
      final input = {
        'protocolVersion': 3,
        'purpose': 'Synthetic local login',
        'items': [
          {
            'credentialId': c.id,
            'destination': {
              'via': 'ego',
              'target': {
                'provider': 'ego',
                'space': 7,
                'pageId': 'p1',
                'instanceId': 'synthetic-browser',
                'url': 'https://synthetic.test/login',
                'form': '#login',
                'field': '#password',
                'structureDigest': 'a' * 64,
              },
            },
          },
        ],
      };
      final body = {
        'sessionSecret': session,
        'operationId': 'local-submit',
        'input': input,
      };
      final denied = await call('$base/request', body, authorized: false);
      expect(denied['status'], 'unauthorized');
      expect(denied['protocolVersion'], 3);
      expect(service.owner.credentialBatches, isEmpty);
      final created = await call('$base/request', body);
      expect(created['status'], 'pending', reason: '$created');
      expect(created['protocolVersion'], 3);
      expect(service.owner.credentialBatches.single.deviceId, 'A' * 22);
      expect(await call('$base/request', body), created);
      expect(
        (await call('$base/request', {
          ...body,
          'deviceId': 'FORGED',
        }))['errorCode'],
        'unknown_field',
      );
      final requestId = created['requestId'];
      await service.owner.decideCredentialBatch(
        requestId as String,
        operationId: 'local-approve',
        revision: 1,
        approvedItems: ['b1'],
      );
      final status = await call('$base/status', {
        'sessionSecret': session,
        'requestId': requestId,
      });
      expect(status['status'], 'approved');
      expect(
        jsonEncode(status),
        isNot(contains('DO-NOT-RETURN-THIS-PASSWORD')),
      );
      expect(jsonEncode(status), isNot(contains('privateProof')));
    },
  );
}
