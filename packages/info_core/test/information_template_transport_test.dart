import 'dart:convert';
import 'dart:io';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'template discovery is optional, strict and never a management route',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> call(
        String path,
        Map<String, Object?> body, {
        String? origin,
      }) async {
        final req = await http.post('127.0.0.1', server.port, path);
        req.headers.contentType = ContentType.json;
        if (origin != null) req.headers.set('Origin', origin);
        req.write(jsonEncode(body));
        final response = await req.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      expect(
        (await call('/templates/catalog', {}))['status'],
        'unsupported_capability',
      );
      expect(
        (await call('/capabilities', {}))['capabilities'],
        isNot(contains('information-template-discovery.v1')),
      );
      var enabled = true;
      service.owner.configureInformationTemplates(
        () => InformationTemplateCatalog(
          version: enabled ? 1 : 2,
          plugins: const [],
          templates: [
            InformationTemplateDescription(
              id: 'local.forms/note',
              name: '说明',
              version: '1.0.0',
              digest: 'a' * 64,
              enabled: enabled,
              definition: {
                'fields': [],
                'instructions': '按原资料填写。',
                'example': {'name': '公开虚构例子', 'values': {}},
              },
            ),
          ],
        ),
      );
      expect(
        (await call('/capabilities', {}))['capabilities'],
        contains('information-template-discovery.v1'),
      );
      final definition = await call('/templates/read', {
        'templateId': 'local.forms/note',
      });
      expect(definition['status'], 'ok');
      expect(
        (definition['template'] as Map)['definition'],
        contains('example'),
      );
      enabled = false;
      expect(
        (await call('/templates/read', {
          'templateId': 'local.forms/note',
        }))['status'],
        'template_unavailable',
      );
      expect(
        (await call('/templates/read', {'templateId': 'absent'}))['status'],
        'template_missing',
      );
      for (final args in [
        <String, Object?>{'limit': 0},
        {'offset': -1},
        {'limit': '1'},
        {'extra': 'PRIVATE'},
        {'offset': null},
      ]) {
        expect(
          (await call('/templates/catalog', args))['status'],
          'invalid_request',
        );
      }
      expect(
        (await call('/templates/read', {
          'templateId': 'local.forms/note',
          'value': 'PRIVATE',
        }))['status'],
        'invalid_request',
      );
      expect(
        (await call(
          '/templates/catalog',
          {},
          origin: 'https://example.invalid',
        ))['status'],
        'unauthorized',
      );
      expect(
        (await call('/templates/install', {'package': 'PRIVATE'}))['status'],
        'unauthorized',
      );
      await service.close();
      expect(
        (await call('/templates/catalog', {}))['status'],
        'service_unavailable',
      );
    },
  );
}
