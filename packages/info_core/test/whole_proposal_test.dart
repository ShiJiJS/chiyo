import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/credential_import_fixture.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  late String session;
  ImportProposal proposal(String id) =>
      repo.importProposals.singleWhere((p) => p.id == id);
  setUp(() {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
    configureCredentialImports(service);
    session = service.agent.openSession('Whole proposal');
  });
  tearDown(() => service.close());

  test(
    'a password batch validates all values before changing one proposal revision',
    () async {
      final id = await service.agent.submitImport(session, [
        for (final key in ['first', 'second'])
          credentialInput(
            key,
            'accountPassword',
            CredentialImportInput.owner(),
          ),
      ]);
      final initial = proposal(id).version;
      await expectLater(
        service.owner.fillImportCredentials(id, initial, {
          'first': 'SYNTHETIC-FIRST',
          'second': '',
        }),
        throwsA(isA<AccessFailure>()),
      );
      expect(proposal(id).version, initial);
      expect(proposal(id).items.every((i) => !i.credential!.ready), true);
      await service.owner.fillImportCredentials(id, initial, {
        'first': 'SYNTHETIC-FIRST',
        'second': 'SYNTHETIC-SECOND',
      });
      expect(proposal(id).version, initial + 1);
      expect(proposal(id).items.every((i) => i.credential!.ready), true);
      expect(repo.managedCredentials, isEmpty);
      expect(
        jsonEncode(service.agent.importStatus(session, id)),
        isNot(contains('SYNTHETIC-')),
      );
      await expectLater(
        service.owner.fillImportCredentials(id, initial, {'first': 'STALE'}),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      expect(repo.managedCredentials, hasLength(2));
    },
  );

  test(
    'legacy partial proposal preserves saved receipts and filled passwords',
    () async {
      final saved = await service.agent.submitImport(session, [
        credentialInput(
          'already-saved',
          'token',
          CredentialImportInput.agentString('SYNTHETIC-OLD'),
        ),
      ]);
      final original = proposal(saved);
      await service.owner.confirmImport(
        saved,
        original.version,
        original.items,
      );
      final old = repo.managedCredentials.single;
      await repo.saveImportProposal(
        ImportProposal(
          id: 'legacy-partial',
          sessionBinding: original.sessionBinding,
          chatLabel: original.chatLabel,
          createdAt: original.createdAt,
          items: [
            credentialInput(
              'remaining-token',
              'token',
              CredentialImportInput.agentString('SYNTHETIC-REMAINING'),
            ),
            credentialInput(
              'remaining-password',
              'accountPassword',
              CredentialImportInput.owner(),
            ),
          ],
          approvedKeys: const ['remaining-token'],
          createdItemKeys: const ['already-saved'],
          createdItemIds: [old.id],
          candidateNames: const {
            'already-saved': 'already-saved',
            'remaining-token': 'remaining-token',
            'remaining-password': 'remaining-password',
          },
          candidateKinds: const {
            'already-saved': 'credential',
            'remaining-token': 'credential',
            'remaining-password': 'credential',
          },
        ),
      );
      await expectLater(
        service.owner.confirmImport(
          'legacy-partial',
          proposal('legacy-partial').version,
          proposal('legacy-partial').items,
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.managedCredentials.length, 1);
      await service.owner.fillImportCredential(
        'legacy-partial',
        proposal('legacy-partial').version,
        'remaining-password',
        'SYNTHETIC-USER-INPUT',
      );
      expect(repo.managedCredentials.length, 1);
      final receipts = await service.owner.confirmImport(
        'legacy-partial',
        proposal('legacy-partial').version,
        proposal('legacy-partial').items,
      );
      expect(receipts.length, 2);
      expect(repo.managedCredentials.length, 3);
      expect(proposal('legacy-partial').receipts.length, 3);
      expect(
        proposal('legacy-partial').receiptFor('already-saved')!.id,
        old.id,
      );
      expect(
        repo.managedCredentials.singleWhere((c) => c.id == old.id).toJson(),
        old.toJson(),
      );
      expect(
        utf8.decode(
          repo.credentialMaterials
              .singleWhere(
                (m) =>
                    m.credentialId ==
                    receipts
                        .singleWhere(
                          (r) =>
                              repo.managedCredentials
                                  .singleWhere((c) => c.id == r.id)
                                  .name ==
                              'remaining-password',
                        )
                        .id,
              )
              .bytes,
        ),
        'SYNTHETIC-USER-INPUT',
      );
    },
  );

  test(
    'seven supplied tokens cannot save before four user passwords are complete',
    () async {
      final id = await service.agent.submitImport(session, [
        for (var i = 0; i < 7; i++)
          credentialInput(
            'token-$i',
            'token',
            CredentialImportInput.agentString('SYNTHETIC-TOKEN-$i'),
          ),
        for (var i = 0; i < 4; i++)
          credentialInput(
            'password-$i',
            'accountPassword',
            CredentialImportInput.owner(),
          ),
      ]);
      await expectLater(
        service.owner.confirmImport(
          id,
          proposal(id).version,
          proposal(id).items.take(7).toList(),
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
      for (var i = 0; i < 4; i++) {
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
        expect(repo.managedCredentials, isEmpty);
        expect(proposal(id).approvedKeys, isEmpty);
        await service.owner.fillImportCredential(
          id,
          proposal(id).version,
          'password-$i',
          'SYNTHETIC-PASSWORD-$i',
        );
        expect(
          jsonEncode(service.agent.importStatus(session, id)),
          isNot(contains('SYNTHETIC-PASSWORD')),
        );
      }
      final receipts = await service.owner.confirmImport(
        id,
        proposal(id).version,
        proposal(id).items,
      );
      expect(receipts.length, 11);
      expect(repo.managedCredentials.length, 11);
      expect(repo.credentialMaterials.length, 11);
      expect(proposal(id).state, ImportProposalState.confirmed);
      expect(
        await service.owner.confirmImport(id, proposal(id).version, const []),
        hasLength(11),
      );
      expect(repo.managedCredentials.length, 11);
      expect(service.owner.credentialUseRequests, isEmpty);
    },
  );

  test(
    'one unresolved reference blocks every member, including unrelated complete members',
    () async {
      final target = await service.agent.submitImport(session, [
        credentialInput(
          'target',
          'token',
          CredentialImportInput.agentString('SYNTHETIC-TARGET'),
        ),
      ]);
      final id = await service.agent.submitImport(session, [
        credentialInput(
          'dependent',
          'token',
          CredentialImportInput.agentString('SYNTHETIC-DEPENDENT'),
          pending: [
            ImportPendingReference('credential', 'target', proposalId: target),
          ],
        ),
        credentialInput(
          'sibling',
          'token',
          CredentialImportInput.agentString('SYNTHETIC-SIBLING'),
        ),
      ]);
      expect(
        await service.owner.confirmImport(
          id,
          proposal(id).version,
          proposal(id).items,
        ),
        isEmpty,
      );
      expect(repo.managedCredentials, isEmpty);
      expect(proposal(id).createdItemIds, isEmpty);
      expect(proposal(id).items.length, 2);
      await service.owner.confirmImport(
        target,
        proposal(target).version,
        proposal(target).items,
      );
      expect(repo.managedCredentials.length, 3);
      expect(proposal(id).state, ImportProposalState.confirmed);
      expect(proposal(id).receipts.length, 2);
    },
  );
}
