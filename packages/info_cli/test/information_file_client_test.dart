import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ambiguous fetch or release response reports unknown and never retries',
    () async {
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final client = AgentClient(
        host.port,
        sessionSecret: 'synthetic-private-session',
      );
      addTearDown(() async {
        client.close();
        await host.close(force: true);
      });
      host.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        paths.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/capabilities') {
          request.response.write(
            jsonEncode({
              'status': 'ok',
              'protocolVersions': [1, 2],
              'capabilities': ['information-attachments.v1'],
            }),
          );
        } else if (request.uri.path.endsWith('/status')) {
          expect(body['operationId'], 'original');
          request.response.write(
            jsonEncode({
              'protocolVersion': 2,
              'status': 'ok',
              'delivery': {'deliveryId': 'receipt', 'state': 'preparing'},
            }),
          );
        } else {
          // The host received the mutation but its response was truncated.
          request.response.write('{');
        }
        await request.response.close();
      });
      final result = await client.execute({
        'command': 'file-fetch',
        'requestId': 'approved',
        'itemId': 'career',
        'fieldId': 'resume',
        'operationId': 'original',
      });
      expect(result['errorCode'], 'delivery_unknown');
      expect(result['operationClaimed'], isTrue);
      expect(result['operationId'], 'original');
      expect(result['retryable'], isFalse);
      expect(paths.where((p) => p.endsWith('/fetch')), hasLength(1));
      final status = await client.execute({
        'command': 'file-status',
        'operationId': 'original',
      });
      expect((status['delivery'] as Map)['state'], 'preparing');
      final release = await client.execute({
        'command': 'file-release',
        'deliveryId': 'receipt',
      });
      expect(release['errorCode'], 'delivery_unknown');
      expect(release['deliveryId'], 'receipt');
      expect(paths.where((p) => p.endsWith('/release')), hasLength(1));
      expect(
        jsonEncode([result, status, release]),
        isNot(contains('synthetic-private-session')),
      );
    },
  );

  test(
    'old hosts, explicit v1, invalid shapes and missing session do not send a fetch',
    () async {
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = AgentClient(host.port, sessionSecret: 'private');
      final anonymous = AgentClient(host.port);
      var calls = 0;
      addTearDown(() async {
        client.close();
        anonymous.close();
        await host.close(force: true);
      });
      host.listen((request) async {
        calls++;
        expect(request.uri.path, '/capabilities');
        await request.drain<void>();
        request.response.write(
          '{"status":"ok","protocolVersions":[1],"capabilities":[]}',
        );
        await request.response.close();
      });
      final input = <String, dynamic>{
        'command': 'file-fetch',
        'requestId': 'approved',
        'itemId': 'career',
        'fieldId': 'resume',
        'operationId': 'original',
      };
      expect(
        (await client.execute(input))['errorCode'],
        'unsupported_capability',
      );
      expect(
        (await client.execute({...input, 'protocolVersion': 1}))['errorCode'],
        'unsupported_protocol',
      );
      expect(
        (await client.execute({...input, 'path': 'arbitrary'}))['errorCode'],
        'invalid_request',
      );
      expect((await anonymous.execute(input))['errorCode'], 'not_authorized');
      expect(
        (await client.execute({
          'command': 'file-status',
          'deliveryId': 'd',
          'operationId': 'op',
        }))['errorCode'],
        'invalid_request',
      );
      expect(
        (await client.execute({
          'command': 'file-release',
          'operationId': 'op',
        }))['errorCode'],
        'invalid_request',
      );
      expect(calls, 1);
    },
  );
}
