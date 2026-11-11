import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'current submissions fail before sending intent to a server that would ignore source fields',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': 'ok',
            'capabilities': ['information-request-operations.v1'],
          }),
        );
        await request.response.close();
      });
      final cli = AgentClient(
        server.port,
        sessionSecret: 'SYNTHETIC_SESSION',
        requireSubmissionMetadata: true,
        sourceAgent: 'Synthetic Agent',
        externalChatId: 'synthetic-chat',
      );
      addTearDown(() async {
        cli.close();
        await server.close(force: true);
      });
      final result = await cli.execute({
        'command': 'request',
        'purpose': '读取合成字段',
        'fields': [
          {'itemId': 'synthetic-item', 'fieldId': 'synthetic-field'},
        ],
      });
      expect(result['status'], 'unsupported_capability');
      expect(paths, ['/capabilities']);
    final unknownVersion = await cli.execute({'command': 'request', 'submissionVersion': 2, 'purpose': '读取合成字段', 'fields': []});
    expect(unknownVersion['fieldErrors'], contains('submissionVersion'));
    expect(paths, ['/capabilities']);
      expect(jsonEncode(result), isNot(contains('SYNTHETIC_SESSION')));
      final missing = await cli.execute({
        'command': 'import-submit',
        'agentName': '',
        'title': '',
        'items': [],
      });
      expect(
        (missing['fieldErrors'] as Map).keys,
        containsAll(['agentName', 'title', 'purpose']),
      );
      final overlong = await cli.execute({
        'command': 'request',
        'agentName': 'x' * 201,
        'purpose': '读取合成字段',
        'fields': [],
      });
      expect(overlong['fieldErrors'], contains('agentName'));
      expect(paths, ['/capabilities']);
    },
  );
}
