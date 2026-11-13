import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test('all help levels work with no context, files, App or stdin', () async {
    final neverRead = Stream<List<int>>.error(
      StateError('stdin must not be read'),
    );
    for (final args in [
      <String>[],
      ['--help'],
      ['fill', '--help'],
      ['fill', 'request', '--help'],
      ['exec', 'request', '--help'],
      ['requests', 'wait', '--help'],
      ['templates', 'examples', '--help'],
      ['chat', 'start', '--help'],
    ]) {
      final result = await ChiyoCli(
        environment: {'CHIYO_CONTEXT': '/missing/private.json'},
        input: neverRead,
      ).run(args);
      expect(result.exitCode, 0);
      expect(result.help, contains('用法：chiyo'));
      expect(result.render(), isNot(contains('/missing/private.json')));
    }
    final json = await ChiyoCli(
      environment: {},
    ).run(['fill', 'request', '--help', '--json']);
    expect(json.output['schemaVersion'], 1);
    expect((json.output['data'] as Map)['help'], contains('--selector'));
    final invalid = await ChiyoCli(
      environment: {},
    ).run(['fill', '--SECRET-DO-NOT-ECHO', '--json']);
    expect(invalid.exitCode, 2);
    expect(invalid.render(), isNot(contains('SECRET-DO-NOT-ECHO')));
    for (final args in [
      ['fill', 'request'],
      ['fill', 'run'],
      [
        'fill',
        'request',
        '--credential',
        'cred',
        '--purpose',
        'login',
        '--via',
        'focus',
        '--url',
        'https://example.test',
      ],
      ['requests', 'wait', 'request-id', '--timeout', '-1'],
      ['proposals', 'check'],
    ]) {
      final result = await ChiyoCli(environment: {}).run([...args, '--json']);
      expect(result.exitCode, 2);
    }
  });

  group('unified CLI over an authenticated local service', () {
    late Directory root;
    late InformationService service;
    late MemoryInformationRepository repository;
    late AgentServer server;
    late File contextFile;
    late ChiyoContext context;
    late AgentConnectionProfile profile;
    late String profilePath;
    Future<ChiyoRunResult> call(List<String> args) => ChiyoCli(
      environment: {'CHIYO_CONTEXT': contextFile.path},
    ).run([...args, '--json']);
    setUp(() async {
      root = await Directory.systemTemp.createTemp('chiyo-cli-');
      repository = MemoryInformationRepository([
        InformationItem('demo-server', 'Synthetic server', '', 1, [
          const InformationField('host', 'Host', '', 'synthetic.invalid', 1),
        ]),
      ]);
      service = InformationService(repository: repository);
      final token = '${'A' * 22}.${'B' * 43}';
      const library = 'synthetic-library-1234';
      server = await AgentServer.start(
        service.agent,
        port: 0,
        connectionToken: token,
        libraryId: library,
      );
      profile = AgentConnectionProfile.local(
        port: server.port,
        deviceToken: token,
        libraryId: library,
      );
      profilePath = (await profile.saveIn(
        Directory('${root.path}/profile'),
      )).path;
      contextFile = File('${root.path}/chat/context.json');
      final opened = await ChiyoCli(environment: {}).run([
        'chat',
        'start',
        '--agent',
        'Independent Agent',
        '--id',
        'current-chat',
        '--label',
        'CLI trial',
        '--connection',
        profilePath,
        '--context-out',
        contextFile.path,
        '--json',
      ]);
      expect(opened.exitCode, 0, reason: opened.render());
      context = await ChiyoContext.load(contextFile, environment: {});
      expect(opened.render(), isNot(contains(context.secret)));
      expect(opened.render(), isNot(contains(context.endCapability!)));
      expect(opened.render(), isNot(contains(contextFile.path)));
      expect(opened.render(), isNot(contains(token)));
    });
    tearDown(() async {
      await server.close();
      await service.close();
      await root.delete(recursive: true);
    });

    test(
      'queries own requests, preserves wait semantics and finds lost submit IDs',
      () async {
        final request = service.agent.request(context.secret, 'read host', [
          const FieldRef('demo-server', 'host'),
        ], operationId: 'recover-submit');
        final stranger = service.agent.openSession('CLI trial');
        final other = service.agent.request(stranger, 'other chat', [
          const FieldRef('demo-server', 'host'),
        ]);
        final list = await call([
          'requests',
          'list',
          '--status',
          'pending',
          '--limit',
          '1',
        ]);
        expect(list.exitCode, 0);
        final rows = (list.output['data'] as Map)['records'] as List;
        expect(rows.single['id'], request.id);
        expect(list.render(), isNot(contains(other.id)));
        final wait = await call([
          'requests',
          'wait',
          request.id,
          '--timeout',
          '0',
        ]);
        expect(wait.exitCode, 6);
        expect(
          service.agent.status(context.secret, request.id)['status'],
          'pending',
        );
        final operations = await call([
          'operations',
          'list',
          '--request',
          request.id,
        ]);
        expect(
          ((operations.output['data'] as Map)['records'] as List).single['id'],
          'recover-submit',
        );
        service.owner.deny(request.id);
        final denied = await call(['requests', 'show', request.id]);
        expect(denied.exitCode, 0);
        expect(denied.output['ok'], true);
        expect((denied.output['data'] as Map)['status'], 'denied');
        final operation = await call(['operations', 'show', 'recover-submit']);
        expect((operation.output['data'] as Map)['requestStatus'], 'denied');
        expect((await call(['requests', 'show', other.id])).output['data'], {
          'status': 'not_found',
        });
      },
    );

    test(
      'host-independent context stays bound and cannot be recovered by a public ID',
      () async {
        final status = await call(['connection', 'show']);
        expect(status.exitCode, 0);
        expect((status.output['data'] as Map)['mode'], 'local');
        final missing = await ChiyoCli(
          environment: {'CODEX_THREAD_ID': 'current-chat'},
        ).run(['requests', 'list', '--json']);
        expect(missing.exitCode, 3);
        expect((missing.output['error'] as Map)['code'], 'context_required');
        final mismatched = await ChiyoCli(
          environment: {
            'CHIYO_CONTEXT': contextFile.path,
            'CHIYO_CHAT_ID': 'another-chat',
          },
        ).run(['requests', 'list', '--json']);
        expect(mismatched.exitCode, 3);
        final ended = await call(['chat', 'end']);
        expect(ended.exitCode, 0);
        expect((await call(['connection', 'show'])).exitCode, 3);
      },
    );

    test(
      'credential search excludes undiscoverable entries, accounts and material',
      () async {
        final c = await service.owner.createStringCredential(
          name: '飞牛 NAS',
          publicPurpose: '管理入口',
          secret: 'SYNTHETIC-PRIVATE-PASSWORD',
        );
        await service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: c.publicPurpose,
          privateNote: 'PRIVATE-NOTE',
          suggestedBinding: c.suggestedBinding,
          discoverable: true,
        );
        await repository.commitCredentials([
          for (final item in repository.managedCredentials)
            item.id == c.id
                ? item.copy(
                    account: 'PRIVATE-ACCOUNT',
                    modifiedAt: item.modifiedAt,
                  )
                : item,
        ], repository.credentialMaterials);
        await service.owner.createStringCredential(
          name: '飞牛 hidden',
          publicPurpose: 'hidden',
          secret: 'HIDDEN-MATERIAL',
        );
        final result = await call(['credentials', 'list', '--query', '飞牛']);
        expect(result.exitCode, 0);
        final rows = (result.output['data'] as Map)['credentials'] as List;
        expect(rows.single['credentialId'], c.id);
        for (final value in [
          'SYNTHETIC-PRIVATE-PASSWORD',
          'PRIVATE-ACCOUNT',
          'PRIVATE-NOTE',
          'HIDDEN-MATERIAL',
        ]) {
          expect(result.render(), isNot(contains(value)));
        }
        expect(
          (await call(['credentials', 'list', '--limit', '0'])).exitCode,
          2,
        );
      },
    );

    test(
      'new context cannot overwrite a previous chat or chmod a general directory',
      () async {
        final original = await contextFile.readAsBytes();
        final result = await ChiyoCli(environment: {}).run([
          'chat',
          'start',
          '--agent',
          'Other',
          '--id',
          'other',
          '--label',
          'Other',
          '--connection',
          profilePath,
          '--context-out',
          contextFile.path,
          '--json',
        ]);
        expect(result.exitCode, 2);
        expect(await contextFile.readAsBytes(), original);
        if (!Platform.isWindows) {
          final public = await Directory('${root.path}/general').create();
          await Process.run('/bin/chmod', ['755', public.path]);
          final target = File('${public.path}/context.json');
          final attempt = await ChiyoCli(environment: {}).run([
            'chat',
            'start',
            '--agent',
            'Other',
            '--id',
            'other',
            '--label',
            'Other',
            '--connection',
            profilePath,
            '--context-out',
            target.path,
            '--json',
          ]);
          expect(attempt.exitCode, 3);
          expect(await target.exists(), false);
          expect((await public.stat()).mode & 0x3f, 0x2d);
        }
      },
    );

    test(
      'template examples come from the current plugin catalog, including all variants',
      () async {
        var pluginVersion = '1.0.0';
        service.owner.configureInformationTemplates(
          () => InformationTemplateCatalog(
            version: 1,
            plugins: const [],
            templates: [
              InformationTemplateDescription(
                id: 'example/note',
                name: 'Example note',
                version: pluginVersion,
                digest: 'a' * 64,
                enabled: true,
                definition: {
                  'fields': [
                    {'key': 'body', 'label': 'Body', 'type': 'text'},
                  ],
                  'instructions': 'Fill the current plugin fields.',
                  'example': {
                    'name': 'Synthetic example',
                    'values': {'body': pluginVersion},
                  },
                },
              ),
            ],
          ),
        );
        final list = await call(['templates', 'list']);
        expect(list.exitCode, 0);
        expect(
          ((list.output['data'] as Map)['templates'] as List).single['id'],
          'example/note',
        );
        final first = await call(['templates', 'examples', 'example/note']);
        expect(first.exitCode, 0);
        expect(((first.output['data'] as Map)['example'] as Map)['values'], {
          'body': '1.0.0',
        });
        pluginVersion = '2.0.0';
        final changed = await call(['templates', 'show', 'example/note']);
        expect(
          ((changed.output['data'] as Map)['template'] as Map)['version'],
          '2.0.0',
        );
      },
    );
  });

  test(
    'real executable emits one JSON result and a meaningful nonzero exit',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/chiyo.dart', '--json', 'requests', 'list'],
        environment: {'CHIYO_CONTEXT': '', 'CODEX_THREAD_ID': ''},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, 3);
      expect(result.stderr, isEmpty);
      final output = jsonDecode(result.stdout as String) as Map;
      expect(output['schemaVersion'], 1);
      expect(output['ok'], false);
      expect((output['error'] as Map)['code'], 'context_required');
    },
  );
}
