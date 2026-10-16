import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'proposal transport limits payloads and never exposes private batches or management',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close();
        service.close();
      });
      Future<Map<String, dynamic>> call(
        String path,
        Map<String, Object?> data, {
        String? origin,
      }) async {
        final request = await http.post('127.0.0.1', server.port, path);
        request.headers.contentType = ContentType.json;
        if (origin != null) request.headers.set('Origin', origin);
        request.write(jsonEncode(data));
        final response = await request.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      final session = service.agent.openSession('A');
      final other = service.agent.openSession('B');
      final input = {
        'sessionSecret': session,
        'items': [
          {
            'name': 'PRIVATE-PENDING-NAME',
            'fields': [
              {'name': 'Host', 'value': 'PRIVATE-PENDING-VALUE'},
            ],
          },
        ],
      };
      final pending = await call('/import/submit', input);
      expect(pending['status'], 'pending');
      expect(pending.toString(), isNot(contains('PRIVATE')));
      expect(
        await call('/import/status', {
          'sessionSecret': other,
          'proposalId': pending['proposalId'],
        }),
        {'status': 'unauthorized'},
      );
      expect(await call('/import/list', {'sessionSecret': session}), {
        'status': 'unauthorized',
      });
      expect(
        await call('/import/confirm', {
          'sessionSecret': session,
          'proposalId': pending['proposalId'],
        }),
        {'status': 'unauthorized'},
      );
      expect(
        await call('/import/submit', input, origin: 'https://evil.invalid'),
        {'status': 'unauthorized'},
      );
      expect(
        (await call('/import/submit', {
          'sessionSecret': session,
          'items': 'PRIVATE-BAD-DATA',
        })).toString(),
        isNot(contains('PRIVATE')),
      );
      Future<void> rejectedSize(String path, Map<String, Object?> input) async {
        try {
          expect(await call(path, input), {'status': 'invalid_request'});
        } on HttpException {
          // Cancelling an oversized chunked HTTP body may close its connection.
          // Either result rejects it without retaining or processing the batch.
        }
      }

      await rejectedSize('/import/submit', {
        'sessionSecret': session,
        'items': [],
        'padding': 'x' * 263000,
      });
      await rejectedSize('/catalog', {'padding': 'x' * 17000});
      expect((await call('/catalog', {}))['status'], 'ok');
      expect(service.owner.importProposals, hasLength(1));
      expect(service.agent.catalog(), isEmpty);
    },
  );
}
