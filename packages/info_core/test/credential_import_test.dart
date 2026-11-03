import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/credential_import_fixture.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  late String session;
  ImportProposal proposal(String id) =>
      service.owner.importProposals.singleWhere((p) => p.id == id);
  setUp(() {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
    configureCredentialImports(service);
    session = service.agent.openSession('合成凭据录入');
  });
  tearDown(() => service.close());

  test(
    'owner password is required, stays private through approval, and admission grants no use',
    () async {
      final id = await service.agent.submitImport(session, [
        credentialInput(
          'password',
          'accountPassword',
          CredentialImportInput.owner(),
        ),
      ]);
      expect(repo.managedCredentials, isEmpty);
      await expectLater(
        service.owner.confirmImport(
          id,
          proposal(id).version,
          proposal(id).items,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'credential_material_required',
          ),
        ),
      );
      expect(proposal(id).approvedKeys, isEmpty);
      await expectLater(
        service.owner.fillImportCredential(
          id,
          proposal(id).version,
          'password',
          '',
        ),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.fillImportCredential(
        id,
        proposal(id).version,
        'password',
        'PRIVATE-OWNER-PASSWORD',
      );
      final status = service.agent.importStatus(session, id);
      expect(jsonEncode(status), isNot(contains('PRIVATE-OWNER')));
      expect(
        jsonEncode(proposal(id).items.single.submissionJson),
        isNot(contains(base64Encode(utf8.encode('PRIVATE-OWNER-PASSWORD')))),
      );
      await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      final saved = repo.managedCredentials.single;
      expect(saved.form, CredentialForm.string);
      expect(saved.template!.typeId, 'credential.accountPassword');
      expect(
        utf8.decode(repo.credentialMaterials.single.bytes),
        'PRIVATE-OWNER-PASSWORD',
      );
      expect(
        jsonEncode(saved.toJson()),
        isNot(contains('PRIVATE-OWNER-PASSWORD')),
      );
      expect(service.owner.information, isEmpty);
      expect(proposal(id).items, isEmpty);
      expect(service.owner.credentialUseRequests, isEmpty);
      expect(service.agent.importStatus(session, id)['status'], 'confirmed');
    },
  );

  test(
    'seen passwords, tokens and whole credential files use dedicated material and scrub terminal drafts',
    () async {
      final bytes = List<int>.generate(300000, (i) => i % 256);
      final id = await service.agent.submitImport(session, [
        credentialInput(
          'seen',
          'accountPassword',
          CredentialImportInput.agentString('PRIVATE-SEEN-PASSWORD'),
        ),
        credentialInput(
          'token',
          'token',
          CredentialImportInput.agentString('PRIVATE-TOKEN'),
        ),
        credentialInput(
          'file',
          'file',
          CredentialImportInput.agentFile('synthetic.key', bytes),
        ),
      ]);
      expect(
        proposal(id).items.every((i) => i.fields.isEmpty && i.values.isEmpty),
        true,
      );
      expect(proposal(id).items.first.credential!.contextExposed, true);
      expect(proposal(id).items.last.credential!.contextExposed, false);
      await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      expect(repo.managedCredentials.length, 3);
      final file = repo.managedCredentials.singleWhere((c) => c.name == 'file');
      expect(file.fileName, 'synthetic.key');
      expect(
        repo.credentialMaterials
            .singleWhere((m) => m.credentialId == file.id)
            .bytes,
        bytes,
      );
      expect(service.owner.information, isEmpty);
      expect(
        jsonEncode(proposal(id).toJson()),
        isNot(contains(base64Encode(utf8.encode('PRIVATE-TOKEN')))),
      );
      final status = service.agent.importStatus(session, id);
      expect(
        (status['items'] as List).every((i) => i['kind'] == 'credential'),
        true,
      );
    },
  );

  test(
    'information, credentials and independent siblings enter as one whole proposal',
    () async {
      final id = await service.agent.submitImport(session, [
        credentialInput(
          'token',
          'token',
          CredentialImportInput.agentString('PRIVATE-CYCLE'),
          pending: [ImportPendingReference('information', 'note')],
        ),
        ImportItemInput(
          '合成说明',
          '',
          [],
          key: 'note',
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': 'PRIVATE-BODY'},
          pendingRelations: {
            'related': [ImportPendingReference('credential', 'token')],
          },
        ),
        credentialInput(
          'independent',
          'token',
          CredentialImportInput.agentString('PRIVATE-INDEPENDENT'),
        ),
      ]);
      await expectLater(
        service.owner.confirmImport(
          id,
          proposal(id).version,
          proposal(id).items.where((i) => i.key != 'note').toList(),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'proposal_incomplete',
          ),
        ),
      );
      expect(repo.managedCredentials, isEmpty);
      expect(repo.items, isEmpty);
      expect(proposal(id).approvedKeys, isEmpty);
      await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      expect(repo.managedCredentials.length, 2);
      final note = repo.items.single,
          token = repo.managedCredentials.singleWhere((c) => c.name == 'token');
      expect(note.layout!.relations['related']!.single.id, token.id);
      expect(token.linkedItemIds, [note.id]);
      expect(token.template!.relations['related']!.single.id, note.id);
      expect(proposal(id).state, ImportProposalState.confirmed);
    },
  );

  test(
    'agent cannot forge an owner-filled material, suppress text exposure, or use the wrong material form',
    () async {
      for (final bad in [
        {'source': 'owner', 'contextExposed': false, 'secret': 'PRIVATE'},
        {
          'source': 'owner',
          'contextExposed': false,
          'material': 'UFJJVkFURQ==',
        },
        {'source': 'agentString', 'contextExposed': false, 'secret': 'PRIVATE'},
      ]) {
        expect(
          () => CredentialImportInput.fromJson(bad),
          throwsFormatException,
        );
      }
      await expectLater(
        service.agent.submitImport(session, [
          credentialInput('wrong', 'token', CredentialImportInput.owner()),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.submitImport(session, [
          credentialInput(
            'wrong',
            'file',
            CredentialImportInput.agentString('PRIVATE'),
          ),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.importProposals, isEmpty);
    },
  );
  test(
    'credentials can reference each other, and rejected references require repair and new approval',
    () async {
      final id = await service.agent.submitImport(session, [
        credentialInput(
          'a',
          'token',
          CredentialImportInput.agentString('FAKE-A'),
          pending: [ImportPendingReference('credential', 'b')],
        ),
        credentialInput(
          'b',
          'token',
          CredentialImportInput.agentString('FAKE-B'),
          pending: [ImportPendingReference('credential', 'a')],
        ),
      ]);
      await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      final a = repo.managedCredentials.singleWhere((c) => c.name == 'a'),
          b = repo.managedCredentials.singleWhere((c) => c.name == 'b');
      expect(a.template!.relations['related']!.single.id, b.id);
      expect(b.template!.relations['related']!.single.id, a.id);
      final target = await service.agent.submitImport(session, [
        credentialInput(
          'rejected',
          'token',
          CredentialImportInput.agentString('FAKE-REJECTED'),
        ),
      ]);
      final dependent = await service.agent.submitImport(session, [
        credentialInput(
          'dependent',
          'token',
          CredentialImportInput.agentString('FAKE-DEPENDENT'),
          pending: [
            ImportPendingReference(
              'credential',
              'rejected',
              proposalId: target,
            ),
          ],
        ),
      ]);
      await service.owner.confirmImport(
        dependent,
        proposal(dependent).version,
        proposal(dependent).items,
      );
      expect(proposal(dependent).awaitingAdmission, true);
      await service.owner.rejectImport(target, proposal(target).version);
      expect(
        service.agent.importStatus(session, dependent)['status'],
        'needs_attention',
      );
      expect(proposal(dependent).approvedKeys, {'dependent'});
      await service.agent
          .reviseImport(session, dependent, proposal(dependent).version, [
            credentialInput(
              'dependent',
              'token',
              CredentialImportInput.agentString('FAKE-DEPENDENT'),
            ),
          ]);
      expect(proposal(dependent).approvedKeys, isEmpty);
      expect(repo.managedCredentials.length, 2);
      await service.owner.confirmImport(
        dependent,
        proposal(dependent).version,
        proposal(dependent).items,
      );
      expect(repo.managedCredentials.length, 3);
    },
  );

  test(
    'an approved information update waits for a pending credential and applies when its material and approval are complete',
    () async {
      final originalId = await service.agent.submitImport(session, [
        ImportItemInput(
          '原说明',
          '',
          [],
          key: 'note',
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': '原内容'},
        ),
      ]);
      await service.owner.confirmImport(
        originalId,
        proposal(originalId).version,
        proposal(originalId).items,
      );
      final original = repo.items.single;
      final credential = await service.agent.submitImport(session, [
        credentialInput(
          'password',
          'accountPassword',
          CredentialImportInput.owner(),
        ),
      ]);
      final update = await service.agent.submitUpdate(
        session,
        UpdateInput(
          original.id,
          original.version,
          [],
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': '新内容'},
          pendingRelations: {
            'related': [
              ImportPendingReference(
                'credential',
                'password',
                proposalId: credential,
              ),
            ],
          },
        ),
      );
      final p = service.owner.updateProposals.singleWhere(
        (p) => p.id == update,
      );
      expect(await service.owner.confirmUpdate(update, p.version), isNull);
      expect(repo.items.single.version, original.version);
      await service.owner.fillImportCredential(
        credential,
        proposal(credential).version,
        'password',
        'FAKE-OWNER',
      );
      await service.owner.confirmImport(
        credential,
        proposal(credential).version,
        proposal(credential).items,
      );
      expect(repo.items.single.fields.single.value, '新内容');
      expect(
        repo.items.single.layout!.relations['related']!.single.id,
        repo.managedCredentials.single.id,
      );
      expect(
        service.owner.updateProposals.singleWhere((p) => p.id == update).state,
        UpdateProposalState.confirmed,
      );
    },
  );

  test(
    'template changes block approval and another session cannot revise or inspect material',
    () async {
      final id = await service.agent.submitImport(session, [
        credentialInput(
          'token',
          'token',
          CredentialImportInput.agentString('PRIVATE'),
        ),
      ]);
      final other = service.agent.openSession('其他聊天');
      expect(
        () => service.agent.importStatus(other, id),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.reviseImport(
          other,
          id,
          proposal(id).version,
          proposal(id).items,
        ),
        throwsA(isA<AccessFailure>()),
      );
      configureCredentialImports(service, digest: 'd' * 64);
      await expectLater(
        service.owner.confirmImport(
          id,
          proposal(id).version,
          proposal(id).items,
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.managedCredentials, isEmpty);
    },
  );
}
