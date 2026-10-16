import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the end route authenticates an independent capability with no read or management authority',
    () async {
      final service = InformationService.fictional();
      final server = await AgentServer.start(service.agent, port: 0);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> call(
        String path,
        Map<String, Object?> body,
      ) async {
        final request = await http.post('127.0.0.1', server.port, path);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        return jsonDecode(await utf8.decoder.bind(await request.close()).join())
            as Map<String, dynamic>;
      }

      final ordinary = await call('/session', {'chatLabel': 'ordinary-cli'});
      expect(ordinary.keys.toSet(), {'status', 'sessionSecret'});
      final opened = await call('/session/lifecycle', {'chatLabel': 'public-chat-id'});
      final session = opened['sessionSecret'] as String;
      final end = opened['endCapability'] as String;
      final pending = await call('/request', {
        'sessionSecret': session,
        'purpose': 'Address',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      for (final capability in [
        'public-chat-id',
        session,
        pending['requestId'] as String,
      ]) {
        expect(
          (await call('/session/end', {'endCapability': capability}))['status'],
          'unauthorized',
        );
      }
      for (final path in [
        '/request',
        '/claim',
        '/session/check',
        '/import/status',
        '/update/status',
      ]) {
        expect(
          (await call(path, {
            'sessionSecret': end,
            'requestId': pending['requestId'],
            'proposalId': 'unknown',
            'purpose': 'Address',
            'fields': [
              {'itemId': 'demo-server', 'fieldId': 'host'},
            ],
          }))['status'],
          'unauthorized',
        );
      }
      for (final path in [
        '/approve',
        '/import/confirm',
        '/backup/export',
        '/history',
      ]) {
        expect(
          (await call(path, {'endCapability': end}))['status'],
          'unauthorized',
        );
      }
      expect(
        (await call('/read', {
          'token': end,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }))['status'],
        'unauthorized',
      );
      expect(await call('/session/end', {'endCapability': end}), {
        'status': 'ended',
      });
      expect(await call('/session/end', {'endCapability': end}), {
        'status': 'ended',
      });
      expect(service.owner.requests.single.state, AccessRequestState.cancelled);
    },
  );
}
