import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:test/test.dart';

void main() {
  for (final supported in [false, true]) {
    test(
      supported
          ? 'lost submit response is unknown and never replayed'
          : 'old server is rejected before submitting an idempotent request',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var submissions = 0;
        server.listen((request) async {
          await request.drain<void>();
          if (request.uri.path == '/capabilities') {
            request.response.write(
              jsonEncode({
                'status': 'ok',
                'capabilities': [
                  if (supported) 'information-request-operations.v1',
                ],
              }),
            );
            await request.response.close();
          } else {
            submissions++;
            // Server received the intent but its response is lost. This must not
            // turn into a confirmed failure or an automatic second submission.
            (await request.response.detachSocket(
              writeHeaders: false,
            )).destroy();
          }
        });
        final client = AgentClient(
          server.port,
          sessionSecret: 'synthetic-secret',
        );
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        final result = await client.execute({
          'command': 'request',
          'operationId': 'lookup-1',
          'purpose': 'inspect',
          'fields': [
            {'itemId': 'i', 'fieldId': 'f'},
          ],
        });
        expect(
          result,
          supported
              ? {'status': 'request_unknown', 'operationId': 'lookup-1'}
              : {'status': 'unsupported_capability'},
        );
        expect(submissions, supported ? 1 : 0);
        expect(result.toString(), isNot(contains('synthetic-secret')));
      },
    );
  }
}
