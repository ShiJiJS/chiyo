import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late MemoryInformationRepository repo;
  late InformationService service;
  late AgentServer server;
  late File contextFile, business;
  var generation = 1;
  InformationTemplateDescription template(String id) =>
      InformationTemplateDescription(
        id: id,
        name: 'Synthetic $id',
        version: '$generation',
        digest: '$generation' * 64,
        enabled: true,
        definition: {
          'recordKind': id == 'credential' ? 'credential' : 'information',
          if (id == 'credential')
            'credential': {
              'form': 'string',
              'secretKind': 'token',
              'suggestedBinding': 'TEST',
            },
          'fields': [
            if (id == 'note')
              {
                'key': 'body',
                'label': 'Body',
                'type': 'text',
                'required': true,
              },
            if (id == 'file')
              {
                'key': 'source',
                'label': 'Source',
                'type': 'file',
                'required': true,
              },
          ],
          'sections': [],
          'relations': [],
          'instructions': 'Use only synthetic test inputs.',
          'example': {'name': 'Synthetic example', 'values': {}},
        },
      );
  Future<ChiyoRunResult> call(
    List<String> args, {
    Map<String, dynamic>? stdin,
  }) => ChiyoCli(
    environment: {'CHIYO_CONTEXT': contextFile.path},
    input: stdin == null
        ? const Stream.empty()
        : Stream.value(utf8.encode(jsonEncode(stdin))),
  ).run([...args, '--json']);
  Map<String, dynamic> note([String value = 'PRIVATE-SYNTHETIC-NOTE']) => {
    'title': 'Synthetic intake',
    'purpose': 'Store a test note',
    'items': [
      {
        'key': 'note',
        'name': 'Synthetic note',
        'templateId': 'note',
        'values': {'body': value},
      },
    ],
  };
  Future<String> check({Map<String, dynamic>? body}) async {
    if (body != null) await business.writeAsString(jsonEncode(body));
    final checked = await call([
      'proposals',
      'check',
      '--input',
      business.path,
    ]);
    expect(checked.exitCode, 0, reason: checked.render());
    return (checked.output['data'] as Map)['checkId'] as String;
  }

  setUp(() async {
    generation = 1;
    root = await Directory.systemTemp.createTemp('chiyo-proposals-');
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
    service.owner.configureInformationTemplates(
      () => InformationTemplateCatalog(
        version: generation,
        plugins: [],
        templates: [
          for (final id in ['note', 'file', 'credential']) template(id),
        ],
      ),
    );
    server = await AgentServer.start(
      service.agent,
      port: 0,
      connectionToken: '${'A' * 22}.${'B' * 43}',
      libraryId: 'synthetic-library-1234',
    );
    contextFile = File('${root.path}/chat/context.json');
    final session = service.agent.openSession('Synthetic proposal CLI');
    final profile = AgentConnectionProfile.local(
      port: server.port,
      libraryId: 'synthetic-library-1234',
      deviceToken: '${'A' * 22}.${'B' * 43}',
    );
    // This server intentionally uses its existing loopback transport. A remote
    // HTTPS fixture covers authenticated online forwarding separately.
    await ChiyoContext(
      chatId: 'proposal-chat',
      agentName: 'Fresh Agent',
      secret: session,
      port: server.port,
      connection: profile,
    ).saveNew(contextFile);
    business = File('${root.path}/input.json');
  });
  tearDown(() async {
    await server.close();
    await service.close();
    await root.delete(recursive: true);
  });
  test(
    'checked updates remain proposals until approval and do not repeat on submission retry',
    () async {
      final item = await service.owner.createInformation(
        'Synthetic old title',
        '',
        [const FieldInput('Body', '', 'PRIVATE-SYNTHETIC-EXISTING')],
      );
      await business.writeAsString(
        jsonEncode({
          'title': 'Rename synthetic note',
          'purpose': 'Update the test title',
          'update': {
            'itemId': item.id,
            'baseVersion': item.version,
            'name': 'Synthetic new title',
          },
        }),
      );
      final checked = await call([
        'proposals',
        'check',
        '--kind',
        'update',
        '--input',
        business.path,
      ]);
      expect(checked.exitCode, 0, reason: checked.render());
      expect(repo.updateProposals, isEmpty);
      final id = (checked.output['data'] as Map)['checkId'] as String;
      final args = [
        'proposals',
        'submit',
        '--kind',
        'update',
        '--check',
        id,
        '--input',
        business.path,
        '--operation',
        'rename-once',
      ];
      final submitted = await call(args);
      expect(submitted.exitCode, 0, reason: submitted.render());
      expect((await call(args)).exitCode, 0);
      expect(repo.updateProposals, hasLength(1));
      expect(service.owner.information.single.name, 'Synthetic old title');
      final proposal = repo.updateProposals.single;
      await service.owner.confirmUpdate(proposal.id, proposal.version);
      expect(service.owner.information.single.name, 'Synthetic new title');
      expect((await call(['operations', 'retry', 'rename-once'])).exitCode, 0);
      expect(repo.updateProposals, hasLength(1));
      expect(submitted.render(), isNot(contains('PRIVATE-SYNTHETIC-EXISTING')));
    },
  );
  test(
    'check freezes dynamic definitions, stores no source text, submits once and recovers by operation',
    () async {
      final checked = await check(body: note());
      expect(repo.importProposals, isEmpty);
      final listBefore = await call(['operations', 'list']);
      expect((listBefore.output['data'] as Map)['localIntents'], isEmpty);
      final args = [
        'proposals',
        'submit',
        '--check',
        checked,
        '--input',
        business.path,
        '--operation',
        'submit-note',
      ];
      final submitted = await call(args);
      expect(submitted.exitCode, 0, reason: submitted.render());
      expect(repo.importProposals, hasLength(1));
      expect(repo.importProposals.single.agentName, 'Fresh Agent');
      expect(repo.importProposals.single.title, 'Synthetic intake');
      expect(repo.items, isEmpty);
      expect((await call(args)).exitCode, 0);
      expect((await call(['operations', 'retry', 'submit-note'])).exitCode, 0);
      expect(repo.importProposals, hasLength(1));
      await for (final file in contextFile.parent.list(recursive: true)) {
        if (file is File && file.path.endsWith('.json')) {
          expect(
            await file.readAsString(),
            isNot(contains('PRIVATE-SYNTHETIC-NOTE')),
          );
        }
      }
    },
  );
  test(
    'modified source or template is rejected before upload or proposal mutation',
    () async {
      final checked = await check(body: note());
      await business.writeAsString(jsonEncode(note('CHANGED-SYNTHETIC')));
      expect(
        (await call([
          'proposals',
          'submit',
          '--check',
          checked,
          '--input',
          business.path,
        ])).exitCode,
        8,
      );
      await business.writeAsString(jsonEncode(note()));
      generation = 2;
      final changed = await call([
        'proposals',
        'submit',
        '--check',
        checked,
        '--input',
        business.path,
      ]);
      expect(changed.exitCode, 8, reason: changed.render());
      expect(repo.importProposals, isEmpty);
      expect((await repo.informationFileStagingUsage()).files, 0);
    },
  );
  test(
    'relative attachment files are checked without upload, changed bytes cannot submit',
    () async {
      final file = File('${root.path}/source.md');
      await file.writeAsString('PRIVATE-SYNTHETIC-ATTACHMENT');
      final checked = await check(
        body: {
          'title': 'Synthetic file',
          'purpose': 'Store test file',
          'items': [
            {
              'key': 'file',
              'name': 'Synthetic source',
              'templateId': 'file',
              'values': {'source': 'primary'},
              'attachments': [
                {
                  'key': 'primary',
                  'name': 'Source',
                  'templateField': 'source',
                  'currentVersion': 1,
                  'versions': [
                    {'filePath': 'source.md'},
                  ],
                },
              ],
            },
          ],
        },
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      await file.writeAsString('CHANGED-SYNTHETIC-ATTACHMENT');
      final bad = await call([
        'proposals',
        'submit',
        '--check',
        checked,
        '--input',
        business.path,
      ]);
      expect(bad.exitCode, 8, reason: bad.render());
      expect((await repo.informationFileStagingUsage()).files, 0);
      expect(repo.importProposals, isEmpty);
      final again = await check();
      final submitted = await call([
        'proposals',
        'submit',
        '--check',
        again,
        '--input',
        business.path,
        '--operation',
        'submit-file',
      ]);
      expect(submitted.exitCode, 0, reason: submitted.render());
      expect(repo.importProposals, hasLength(1));
      expect((await repo.informationFileStagingUsage()).files, 1);
      expect(
        (await call([
          'proposals',
          'submit',
          '--check',
          again,
          '--input',
          business.path,
          '--operation',
          'submit-file',
        ])).exitCode,
        0,
      );
      expect((await repo.informationFileStagingUsage()).files, 1);
    },
  );
  test(
    'stdin token stays out of local journals and every check remains chat scoped',
    () async {
      final input = {
        'title': 'Synthetic token',
        'purpose': 'Store synthetic token',
        'items': [
          {
            'key': 'token',
            'name': 'Synthetic token',
            'templateId': 'credential',
            'credential': {
              'source': 'agentString',
              'contextExposed': true,
              'secret': 'PRIVATE-SYNTHETIC-TOKEN',
            },
          },
        ],
      };
      final checked = await call([
        'proposals',
        'check',
        '--input',
        '-',
      ], stdin: input);
      expect(checked.exitCode, 0, reason: checked.render());
      final id = (checked.output['data'] as Map)['checkId'] as String;
      final submitted = await call([
        'proposals',
        'submit',
        '--check',
        id,
        '--input',
        '-',
        '--operation',
        'stdin-token',
      ], stdin: input);
      expect(submitted.exitCode, 0, reason: submitted.render());
      expect(repo.importProposals, hasLength(1));
      await for (final file in contextFile.parent.list(recursive: true)) {
        if (file is File && file.path.endsWith('.json')) {
          expect(
            await file.readAsString(),
            isNot(contains('PRIVATE-SYNTHETIC-TOKEN')),
          );
        }
      }
      final other = File('${root.path}/other-chat/context.json');
      final old = await ChiyoContext.load(contextFile, environment: {});
      await ChiyoContext(
        chatId: 'other-chat',
        agentName: 'Fresh Agent',
        secret: service.agent.openSession('Other chat'),
        port: server.port,
        connection: old.connection,
      ).saveNew(other);
      final denied = await ChiyoCli(
        environment: {'CHIYO_CONTEXT': other.path},
        input: Stream.value(utf8.encode(jsonEncode(input))),
      ).run(['proposals', 'submit', '--check', id, '--input', '-', '--json']);
      expect(denied.exitCode, 8);
      expect(repo.importProposals, hasLength(1));
    },
  );
}
