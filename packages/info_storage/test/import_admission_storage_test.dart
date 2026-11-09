import 'support/encrypted_artifacts.dart';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'waiting approvals survive restart and cross-proposal admission rolls back with its owner receipt',
    () async {
      final root = await Directory.systemTemp.createTemp('admission-storage-');
      final keys = TestKeyStore();
      late EncryptedInformationRepository repo;
      late InformationService service;
      Future<void> open() async {
        repo = await EncryptedInformationRepository.open(root.path, keys);
        service = InformationService(repository: repo);
        service.owner.configureInformationTemplates(
          () => InformationTemplateCatalog(
            version: 1,
            plugins: [],
            templates: [
              InformationTemplateDescription(
                id: 'note',
                name: '说明',
                version: '1',
                digest: 'a' * 64,
                enabled: true,
                definition: {
                  'fields': [
                    {'key': 'body', 'label': '正文', 'type': 'text'},
                  ],
                  'sections': [],
                  'relations': [
                    {'key': 'related', 'label': '相关资料'},
                  ],
                  'instructions': '填写说明。',
                  'example': {
                    'name': '示例',
                    'values': {'body': '示例'},
                  },
                },
              ),
            ],
          ),
        );
      }

      Future<void> close() async {
        await service.close();
        await repo.close();
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      ImportItemInput input(String key, {String? targetProposal}) =>
          ImportItemInput(
            key,
            '',
            [],
            key: key,
            templateId: 'note',
            templateVersion: '1',
            templateDigest: 'a' * 64,
            values: {'body': 'PRIVATE-ADMISSION-$key'},
            pendingRelations: {
              if (targetProposal != null)
                'related': [
                  ImportPendingReference(
                    'information',
                    'target',
                    proposalId: targetProposal,
                  ),
                ],
            },
          );
      ImportProposal proposal(String id) =>
          service.owner.importProposals.singleWhere((p) => p.id == id);
      Future<OwnerProposalReceipt> approve(String id, String operation) {
        final p = proposal(id);
        return service.owner.performProposalDecision(
          OwnerProposalCommand(
            operationId: operation,
            proposalId: id,
            kind: ProposalKind.addition,
            confirm: true,
            version: p.version,
            reviewToken: 'b' * 64,
            commandDigest: 'c' * 64,
          ),
          validate: () {
            if (proposal(id).version != p.version)
              throw const AccessFailure('proposal_changed');
          },
          decide: () async {
            await service.owner.confirmImport(id, p.version, p.items);
          },
        );
      }

      void sql(String statement) {
        final db = sqlite3.open('${root.path}/library.db');
        try {
          final hex = keys.key!
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          db.execute(statement);
        } finally {
          db.close();
        }
      }

      final session = service.agent.openSession('合成聊天');
      final target = await service.agent.submitImport(session, [
        input('target'),
      ]);
      final dependent = await service.agent.submitImport(session, [
        input('dependent', targetProposal: target),
      ]);
      final waiting = await approve(dependent, 'dependent-approval');
      expect(waiting.records, isEmpty);
      expect(waiting.awaitingKeys, ['dependent']);
      expect(service.owner.information, isEmpty);
      await close();
      await open();
      expect(proposal(dependent).awaitingAdmission, true);
      expect(
        proposal(dependent).items.single.values['body'],
        'PRIVATE-ADMISSION-dependent',
      );
      expect(
        (await service.owner.ownerProposalReceipt(
          'dependent-approval',
        ))!.awaitingKeys,
        ['dependent'],
      );
      sql(
        "CREATE TRIGGER fail_admission_receipt BEFORE INSERT ON owner_proposal_operations WHEN NEW.operation_id='target-approval' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await expectLater(
        approve(target, 'target-approval'),
        throwsA(isA<StorageFailure>()),
      );
      expect(service.owner.information, isEmpty);
      expect(proposal(target).approvedKeys, isEmpty);
      expect(proposal(dependent).awaitingAdmission, true);
      await close();
      await open();
      expect(service.owner.information, isEmpty);
      expect(proposal(target).state, ImportProposalState.pending);
      expect(proposal(dependent).awaitingAdmission, true);
      sql('DROP TRIGGER fail_admission_receipt');
      final saved = await approve(target, 'target-approval');
      expect(saved.records.length, 1);
      expect(saved.awaitingKeys, isEmpty);
      final targetRecord = service.owner.information.singleWhere(
        (i) => i.name == 'target',
      );
      expect(
        service.owner.information
            .singleWhere((i) => i.name == 'dependent')
            .layout!
            .relations['related']!
            .single
            .id,
        targetRecord.id,
      );
      expect(proposal(dependent).items, isEmpty);
      expect(proposal(dependent).state, ImportProposalState.confirmed);
      await close();
      await open();
      expect(service.owner.information.length, 2);
      expect(proposal(dependent).version, 3);
      expect(
        (await service.owner.ownerProposalReceipt(
          'target-approval',
        ))!.records.single.id,
        targetRecord.id,
      );
      // The first operation truthfully records what happened then: approval waited.
      expect(
        (await service.owner.ownerProposalReceipt(
          'dependent-approval',
        ))!.awaitingKeys,
        ['dependent'],
      );
      final nextSession = service.agent.openSession('合成修改测试');
      final newTarget = await service.agent.submitImport(nextSession, [
        input('new-target'),
      ]);
      final original = service.owner.information.singleWhere(
        (i) => i.name == 'dependent',
      );
      final modification = await service.agent.submitUpdate(
        nextSession,
        UpdateInput(
          original.id,
          original.version,
          [],
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': 'PRIVATE-UPDATE-REVIEWED'},
          pendingRelations: {
            'related': [
              ImportPendingReference(
                'information',
                'new-target',
                proposalId: newTarget,
              ),
            ],
          },
        ),
      );
      final reviewedDirectory = await service.owner.createDirectory('主人核对的目录');
      final pendingUpdate = service.owner.updateProposals.singleWhere(
        (p) => p.id == modification,
      );
      final updateReceipt = await service.owner.performProposalDecision(
        OwnerProposalCommand(
          operationId: 'modification-approval',
          proposalId: modification,
          kind: ProposalKind.modification,
          confirm: true,
          version: pendingUpdate.version,
          reviewToken: 'd' * 64,
          commandDigest: 'e' * 64,
        ),
        validate: () {
          if (service.owner.updateProposals
                  .singleWhere((p) => p.id == modification)
                  .version !=
              pendingUpdate.version)
            throw const AccessFailure('proposal_changed');
        },
        decide: () async {
          expect(
            await service.owner.confirmUpdate(
              modification,
              pendingUpdate.version,
              review: UpdateReview(
                pendingUpdate.input,
                directoryId: reviewedDirectory.id,
              ),
            ),
            isNull,
          );
        },
      );
      expect(updateReceipt.records, isEmpty);
      expect(updateReceipt.awaitingKeys, [original.id]);
      expect(
        service.owner.information
            .singleWhere((i) => i.id == original.id)
            .version,
        original.version,
      );
      await close();
      await open();
      final retained = service.owner.updateProposals.singleWhere(
        (p) => p.id == modification,
      );
      expect(retained.approved, true);
      expect(retained.approvedReview!.directoryId, reviewedDirectory.id);
      expect(retained.input.values['body'], 'PRIVATE-UPDATE-REVIEWED');
      sql(
        "CREATE TRIGGER fail_update_release BEFORE INSERT ON owner_proposal_operations WHEN NEW.operation_id='new-target-approval' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await expectLater(
        approve(newTarget, 'new-target-approval'),
        throwsA(isA<StorageFailure>()),
      );
      expect(service.owner.information.length, 2);
      expect(
        service.owner.information
            .singleWhere((i) => i.id == original.id)
            .fields
            .single
            .value,
        'PRIVATE-ADMISSION-dependent',
      );
      expect(service.owner.informationRevisions, isEmpty);
      await close();
      await open();
      expect(
        service.owner.updateProposals
            .singleWhere((p) => p.id == modification)
            .approved,
        true,
      );
      sql('DROP TRIGGER fail_update_release');
      await approve(newTarget, 'new-target-approval');
      final current = service.owner.information.singleWhere(
            (i) => i.id == original.id,
          ),
          referenced = service.owner.information.singleWhere(
            (i) => i.name == 'new-target',
          );
      expect(current.fields.single.value, 'PRIVATE-UPDATE-REVIEWED');
      expect(current.layout!.relations['related']!.single.id, referenced.id);
      expect(current.directoryId, reviewedDirectory.id);
      expect(
        service.owner.informationRevisions.single.item.fields.single.value,
        'PRIVATE-ADMISSION-dependent',
      );
      await close();
      await open();
      expect(
        service.owner.updateProposals
            .singleWhere((p) => p.id == modification)
            .state,
        UpdateProposalState.confirmed,
      );
      expect(
        service.owner.information
            .singleWhere((i) => i.id == original.id)
            .version,
        2,
      );
      for (final file in root.listSync().whereType<File>()) {
        expect(
          String.fromCharCodes(encryptedArtifactBytes(file)),
          isNot(contains('PRIVATE-ADMISSION')),
        );
        expect(
          String.fromCharCodes(encryptedArtifactBytes(file)),
          isNot(contains('PRIVATE-UPDATE')),
        );
      }
    },
  );
}
