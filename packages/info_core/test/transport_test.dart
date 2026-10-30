import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'legacy requests cannot bypass file protocol checks beyond the catalog first page',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository([
          for (var i = 0; i < 25; i++)
            InformationItem('text-$i', 'Text $i', '', 1, [
              InformationField('f-$i', 'Text', '', 'synthetic', 1),
            ]),
          InformationItem('file-item', 'File', '', 1, [
            InformationField.file(
              'file-field',
              'Attachment',
              '',
              InformationAttachmentRef('synthetic-file', 1),
              1,
            ),
          ]),
        ]),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        await service.close();
      });
      expect(service.agent.searchCatalog().items, hasLength(20));
      expect(service.agent.catalog(), hasLength(26));
      final request = await client.post('127.0.0.1', server.port, '/request');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'sessionSecret': service.agent.openSession('synthetic'),
          'purpose': 'legacy file request',
          'fields': [
            {'itemId': 'file-item', 'fieldId': 'file-field'},
          ],
        }),
      );
      final response =
          jsonDecode(await utf8.decoder.bind(await request.close()).join())
              as Map;
      expect(response['status'], 'unsupported_capability');
      expect(service.owner.requests, isEmpty);
    },
  );

  test(
    'loopback transport supports approval flow but exposes no management routes',
    () async {
      final service = InformationService.fictional();
      final server = await AgentServer.start(service.agent, port: 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        service.close();
      });
      Future<Map<String, dynamic>> call(
        String path,
        Map<String, dynamic> body, {
        String? origin,
      }) async {
        final request = await client.post('127.0.0.1', server.port, path);
        request.headers.contentType = ContentType.json;
        if (origin != null) request.headers.set('Origin', origin);
        request.write(jsonEncode(body));
        final response = await request.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      expect((await call('/catalog', {}))['status'], 'ok');
      expect((await call('/approve', {}))['status'], 'unauthorized');
      expect((await call('/revoke', {}))['status'], 'unauthorized');
      expect(
        (await call('/catalog', {}, origin: 'https://evil.invalid'))['status'],
        'unauthorized',
      );
      final secret = (await call('/session', {
        'chatLabel': 'chat',
      }))['sessionSecret'];
      for (final route in ['/app/quit', '/owner/quit']) {
        expect(
          (await call(route, {'sessionSecret': secret}))['status'],
          'unauthorized',
        );
      }
      final id =
          (await call('/request', {
                'sessionSecret': secret,
                'purpose': 'demo',
                'fields': [
                  {'itemId': 'demo-server', 'fieldId': 'host'},
                ],
              }))['requestId']
              as String;
      expect(
        (await call('/claim', {
          'sessionSecret': secret,
          'requestId': id,
        }))['status'],
        'pending',
      );
      service.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      final token = (await call('/claim', {
        'sessionSecret': secret,
        'requestId': id,
      }))['token'];
      expect(
        (await call('/read', {
          'token': token,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['value'],
        'demo.example.invalid',
      );
      expect(
        (await call('/read', {
          'token': token,
          'itemId': 'demo-server',
          'fieldId': 'username',
        }))['status'],
        'unauthorized',
      );
    },
  );
}
