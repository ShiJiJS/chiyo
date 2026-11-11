import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test('authenticated readiness is independent of tool verification', () async {
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    final toolStarted = Completer<void>();
    final tools = Completer<List<CredentialToolLocation>>();
    var toolCalls = 0;
    final token = '${'d' * 22}.${'e' * 43}';
    const identity = 'local-readiness-fixture';
    final server = await AgentServer.start(
      service.agent,
      port: 0,
      connectionToken: token,
      libraryId: identity,
      credentialTools: () {
        toolCalls++;
        if (!toolStarted.isCompleted) toolStarted.complete();
        return tools.future;
      },
    );
    final client = HttpClient();
    addTearDown(() async {
      if (!tools.isCompleted) tools.complete([]);
      client.close(force: true);
      await server.close();
      await service.close();
    });
    Future<Map<String, dynamic>> call(
      String path, {
      String? bearer,
      String serverId = identity,
      Map<String, Object?> body = const {},
    }) async {
      final request = await client.post('127.0.0.1', server.port, path);
      request.headers.contentType = ContentType.json;
      request.headers.set('authorization', 'Bearer ${bearer ?? token}');
      request.headers.set('x-chiyo-server-id', serverId);
      request.write(jsonEncode(body));
      final response = await request.close();
      expect(response.headers.value('x-chiyo-server-id'), identity);
      return jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>;
    }

    expect(await call('/health'), {'protocolVersion': 1, 'status': 'ok'});
    expect(toolCalls, 0);
    expect((await call('/health', bearer: 'wrong'))['status'], 'unauthorized');
    expect(
      (await call('/health', serverId: 'wrong'))['status'],
      'unauthorized',
    );
    expect(
      (await call('/health', body: {'unexpected': true}))['status'],
      'invalid_request',
    );

    var capabilitiesCompleted = false;
    final capabilities = call('/capabilities').then((result) {
      capabilitiesCompleted = true;
      return result;
    });
    await toolStarted.future.timeout(const Duration(seconds: 2));
    expect(capabilitiesCompleted, isFalse);
    expect(await call('/health'), {'protocolVersion': 1, 'status': 'ok'});
    expect(toolCalls, 1);
    tools.complete([]);
    final result = await capabilities;
    expect(result['status'], 'ok');
    expect(result['credentialTools'], isEmpty);
    expect(service.owner.sessions, isEmpty);
  });
}
