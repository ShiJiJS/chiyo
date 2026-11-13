import 'dart:convert';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/file_import_fixture.dart';
import 'fixtures/credential_import_fixture.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  late String session;
  Map<String, dynamic> body(Map<String, dynamic> content) => {
    'title': 'Synthetic intake',
    'purpose': 'Check synthetic documents',
    'agentName': 'Trial Agent',
    'externalChatId': 'synthetic-chat',
    ...content,
  };
  Matcher failure(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
  setUp(() {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
    session = service.agent.openSession('Synthetic checks');
  });
  tearDown(() => service.close());
  Map<String, dynamic> note([String text = 'PRIVATE-SYNTHETIC-NOTE']) => {
    'key': 'note',
    'name': 'Synthetic note',
    'templateId': 'note',
    'templateVersion': '1',
    'templateDigest': 'a' * 64,
    'values': {'body': text},
  };
  test(
    'dry run compiles current templates and returns no input values or saved facts',
    () async {
      configureCredentialImports(service);
      final input = body({
        'items': [
          note(),
          credentialInput(
            'password',
            'accountPassword',
            CredentialImportInput.owner(),
          ).submissionJson,
        ],
      });
      final result = service.agent.checkProposal(session, 'import', input);
      expect(result['checked'], true);
      expect(
        ((result['items'] as List).last as Map)['requiresUserPassword'],
        true,
      );
      expect(jsonEncode(result), isNot(contains('PRIVATE-SYNTHETIC')));
      expect(repo.importProposals, isEmpty);
      expect(repo.items, isEmpty);
      expect(repo.managedCredentials, isEmpty);
      expect((await repo.informationFileStagingUsage()).files, 0);
      final id = await service.agent.submitImport(
        session,
        (input['items'] as List)
            .map((r) => ImportItemInput.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
      );
      expect(repo.importProposals.single.id, id);
      expect(repo.items, isEmpty);
    },
  );
  test(
    'file metadata can check required file fields without upload or byte storage',
    () async {
      configureFileImports(service);
      final row = {
        'key': 'document',
        'name': 'Synthetic file',
        'templateId': 'file',
        'templateVersion': '1',
        'templateDigest': 'a' * 64,
        'values': {'file': 'primary'},
        'attachments': [
          {
            'key': 'primary',
            'name': 'Source',
            'templateField': 'file',
            'currentVersion': 1,
            'versions': [
              {
                'originalName': 'synthetic.md',
                'mediaType': 'text/plain',
                'byteLength': 42,
                'sha256': 'b' * 64,
              },
            ],
          },
        ],
      };
      final result = service.agent.checkProposal(
        session,
        'import',
        body({
          'items': [row],
        }),
      );
      expect(((result['items'] as List).single as Map)['fileCount'], 1);
      expect((await repo.informationFileStagingUsage()).files, 0);
      expect(repo.importProposals, isEmpty);
      final malicious = jsonDecode(jsonEncode(row)) as Map<String, dynamic>;
      ((malicious['attachments'] as List).single['versions'] as List)
          .single['upload'] = {
        'consumed': false,
      };
      expect(
        () => service.agent.checkProposal(
          session,
          'import',
          body({
            'items': [malicious],
          }),
        ),
        failure('invalid_proposal'),
      );
    },
  );
  test(
    'invalid values and missing dependencies fail before any proposal is created',
    () {
      configureCredentialImports(service);
      final bad = note()
        ..['values'] = {
          'body': {'invalid': true},
        };
      expect(
        () => service.agent.checkProposal(
          session,
          'import',
          body({
            'items': [bad],
          }),
        ),
        failure('validation_failed'),
      );
      final dependency = note()
        ..['relations'] = {
          'related': [
            {'kind': 'information', 'itemKey': 'absent'},
          ],
        };
      expect(
        () => service.agent.checkProposal(
          session,
          'import',
          body({
            'items': [dependency],
          }),
        ),
        failure('invalid_reference'),
      );
      expect(repo.importProposals, isEmpty);
    },
  );
  test('template disable and digest changes invalidate a previous check', () {
    configureCredentialImports(service);
    final input = body({
      'items': [note()],
    });
    expect(
      service.agent.checkProposal(session, 'import', input)['checked'],
      true,
    );
    service.owner.configureInformationTemplates(
      () => InformationTemplateCatalog(
        version: 2,
        plugins: [],
        templates: [
          InformationTemplateDescription(
            id: 'note',
            name: 'Changed',
            version: '2',
            digest: 'b' * 64,
            enabled: true,
            definition: {
              'fields': [],
              'instructions': 'Use current fields.',
              'example': {},
            },
          ),
        ],
      ),
    );
    expect(
      () => service.agent.checkProposal(session, 'import', input),
      failure('template_changed'),
    );
    expect(repo.importProposals, isEmpty);
  });
  test(
    'update and delete checks preserve owner-side existence checks and store nothing',
    () {
      final changed = body({
        'update': {
          'itemId': 'not-an-existence-oracle',
          'baseVersion': 1,
          'name': 'Synthetic rename',
        },
      });
      expect(
        service.agent.checkProposal(session, 'update', changed)['checked'],
        true,
      );
      expect(
        service.agent.checkProposal(
          session,
          'delete',
          body({'itemId': 'not-an-existence-oracle', 'baseVersion': 1}),
        )['checked'],
        true,
      );
      expect(repo.updateProposals, isEmpty);
      expect(repo.deleteProposals, isEmpty);
      expect(
        () => service.agent.checkProposal(
          session,
          'delete',
          body({'itemId': 'x', 'baseVersion': 0}),
        ),
        failure('invalid_proposal'),
      );
      expect(
        () => service.agent.checkProposal(
          'other-chat',
          'delete',
          body({'itemId': 'x', 'baseVersion': 1}),
        ),
        failure('unauthorized'),
      );
    },
  );
  test(
    'Agent protocol routes strict dry run with authenticated session only',
    () async {
      configureCredentialImports(service);
      final protocol = AgentProtocol(service.agent);
      final caps = await protocol.dispatch('/capabilities', {});
      expect(
        caps['capabilities'],
        contains('information-proposal-precheck.v1'),
      );
      final result = await protocol.dispatch('/proposals/check', {
        'sessionSecret': session,
        'kind': 'import',
        'input': body({
          'items': [note()],
        }),
      });
      expect(result['checked'], true);
      expect(repo.importProposals, isEmpty);
      await expectLater(
        protocol.dispatch('/proposals/check', {
          'sessionSecret': session,
          'kind': 'import',
          'input': body({
            'items': [note()],
          }),
          'owner': true,
        }),
        failure('invalid_request'),
      );
    },
  );
}
