import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'online precheck accepts bounded credential-file batches without persisting material',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      f.runtime.service.owner.configureInformationTemplates(
        () => InformationTemplateCatalog(
          version: 1,
          plugins: [],
          templates: [
            InformationTemplateDescription(
              id: 'synthetic/identity',
              name: 'Synthetic identity',
              version: '1',
              digest: 'b' * 64,
              enabled: true,
              definition: {
                'recordKind': 'credential',
                'credential': {
                  'form': 'file',
                  'secretKind': 'file',
                  'suggestedBinding': 'IDENTITY',
                },
                'fields': [],
                'sections': [],
                'relations': [],
                'instructions': 'Use synthetic files only.',
                'example': {'name': 'Synthetic identity', 'values': {}},
              },
            ),
          ],
        ),
      );
      final chat = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic large credential precheck',
      });
      final context = File('${f.root.path}/large-cli-chat/context.json');
      await ChiyoContext(
        chatId: 'large-credential-check',
        agentName: 'Trial Agent',
        secret: chat['sessionSecret'] as String,
        port: f.profiles.first.address.port,
        connection: f.profiles.first,
      ).saveNew(context);
      final source = File('${f.root.path}/large-proposal.json');
      final files = [
        for (var n = 0; n < 2; n++) File('${f.root.path}/synthetic-$n.key'),
      ];
      for (final file in files)
        await file.writeAsBytes(List.filled(1048576, 65));
      await source.writeAsString(
        jsonEncode({
          'title': 'Synthetic identities',
          'purpose': 'Check two whole credential files',
          'items': [
            for (final (n, file) in files.indexed)
              {
                'key': 'identity-$n',
                'name': 'Synthetic identity $n',
                'templateId': 'synthetic/identity',
                'credential': {
                  'source': 'agentFile',
                  'contextExposed': false,
                  'filePath': file.path,
                },
              },
          ],
        }),
      );
      final result = await ChiyoCli(
        environment: {'CHIYO_CONTEXT': context.path},
      ).run(['proposals', 'check', '--input', source.path, '--json']);
      expect(result.exitCode, 0, reason: result.render());
      expect(f.runtime.service.owner.importProposals, isEmpty);
      expect(f.runtime.service.owner.credentials, isEmpty);
      expect((await f.repo.informationFileStagingUsage()).files, 0);
    },
  );
  test(
    'HTTPS SQLCipher dry run writes no proposal and lost submission reply recovers once across restart',
    () async {
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/import/submit',
      );
      addTearDown(f.dispose);
      void configure() => f.runtime.service.owner.configureInformationTemplates(
        () => InformationTemplateCatalog(
          version: 1,
          plugins: [],
          templates: [
            InformationTemplateDescription(
              id: 'synthetic/note',
              name: 'Synthetic note',
              version: '1',
              digest: 'a' * 64,
              enabled: true,
              definition: {
                'fields': [
                  {
                    'key': 'body',
                    'label': 'Body',
                    'type': 'text',
                    'required': true,
                  },
                ],
                'sections': [],
                'relations': [],
                'instructions': 'Fill only synthetic content.',
                'example': {
                  'name': 'Synthetic example',
                  'values': {'body': 'Example'},
                },
              },
            ),
          ],
        ),
      );
      configure();
      final opened = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic proposal recovery',
      });
      final context = File('${f.root.path}/cli-chat/context.json');
      await ChiyoContext(
        chatId: 'proposal-recovery',
        agentName: 'Fresh Trial Agent',
        secret: opened['sessionSecret'] as String,
        port: f.profiles.first.address.port,
        connection: f.profiles.first,
      ).saveNew(context);
      final source = File('${f.root.path}/proposal.json');
      await source.writeAsString(
        jsonEncode({
          'title': 'Synthetic note intake',
          'purpose': 'Test proposal recovery',
          'items': [
            {
              'key': 'note',
              'name': 'Synthetic note',
              'templateId': 'synthetic/note',
              'values': {'body': 'PRIVATE-SYNTHETIC-SOURCE'},
            },
          ],
        }),
      );
      Future<ChiyoRunResult> call(List<String> args) => ChiyoCli(
        environment: {'CHIYO_CONTEXT': context.path},
      ).run([...args, '--json']);
      final example = await call(['templates', 'examples', 'synthetic/note']);
      expect(example.exitCode, 0, reason: example.render());
      final business =
          (example.output['data'] as Map)['submissionExample'] as Map;
      expect(business.containsKey('command'), false);
      expect(business.containsKey('operationId'), false);
      expect(business.containsKey('agentName'), false);
      expect(
        (business['items'] as List).single.containsKey('templateDigest'),
        false,
      );
      final checked = await call([
        'proposals',
        'check',
        '--input',
        source.path,
      ]);
      expect(checked.exitCode, 0, reason: checked.render());
      expect(f.runtime.service.owner.importProposals, isEmpty);
      final id = (checked.output['data'] as Map)['checkId'] as String;
      final unknown = await call([
        'proposals',
        'submit',
        '--check',
        id,
        '--input',
        source.path,
        '--operation',
        'lost-proposal',
      ]);
      expect(unknown.exitCode, 7, reason: unknown.render());
      expect(f.runtime.service.owner.importProposals, hasLength(1));
      final proposal = f.runtime.service.owner.importProposals.single;
      final createdAt = proposal.createdAt.toUtc();
      expect(proposal.agentName, 'Fresh Trial Agent');
      expect(proposal.externalChatId, 'proposal-recovery');
      expect(f.runtime.service.owner.information, isEmpty);
      final recovered = await call(['operations', 'retry', 'lost-proposal']);
      expect(recovered.exitCode, 0, reason: recovered.render());
      expect((recovered.output['data'] as Map)['requestId'], proposal.id);
      expect(f.runtime.service.owner.importProposals, hasLength(1));
      expect(
        f.runtime.service.owner.importProposals.single.createdAt.toUtc(),
        createdAt,
      );
      await f.reopen();
      configure();
      final original = await call(['operations', 'show', 'lost-proposal']);
      expect(original.exitCode, 0, reason: original.render());
      expect((original.output['data'] as Map)['requestId'], proposal.id);
      expect(
        f.runtime.service.owner.importProposals.single.createdAt.toUtc(),
        createdAt,
      );
      expect(original.render(), isNot(contains('PRIVATE-SYNTHETIC-SOURCE')));
      expect(checked.render(), isNot(contains('PRIVATE-SYNTHETIC-SOURCE')));
    },
  );
}
