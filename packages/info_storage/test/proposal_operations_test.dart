import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = InformationService(repository: repo);
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('proposal-operations-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  OwnerProposalCommand command(
    String op,
    String id,
    ProposalKind kind, {
    bool confirm = true,
  }) => OwnerProposalCommand(
    operationId: op,
    proposalId: id,
    kind: kind,
    confirm: confirm,
    version: 1,
    reviewToken: 'a' * 64,
    commandDigest: 'b' * 64,
  );
  Future<OwnerProposalReceipt> decide(
    OwnerProposalCommand c,
    Future<void> Function() action,
  ) =>
      service.owner.performProposalDecision(c, validate: () {}, decide: action);
  Future<String> addition(String session) =>
      service.agent.submitImport(session, [
        ImportItemInput('合成资料', '', [const FieldInput('字段', '', '合成正文')]),
      ]);
  test(
    'import commit and rejection have exact receipts across reopen and duplicate intent',
    () async {
      final session = service.agent.openSession('合成聊天');
      final id = await addition(session);
      final c = command('import-1', id, ProposalKind.addition);
      final receipt = await decide(c, () async {
        await service.owner.confirmImport(
          id,
          1,
          service.owner.importProposals.single.items,
        );
      });
      expect(receipt.records.single.id, service.owner.information.single.id);
      final rejected = await addition(session);
      await decide(
        command('reject-1', rejected, ProposalKind.addition, confirm: false),
        () => service.owner.rejectImport(rejected, 1),
      );
      await close();
      await open();
      final again = await decide(c, () async {
        fail('a committed decision must not run again');
      });
      expect(again.records.single.id, receipt.records.single.id);
      expect(service.owner.information.length, 1);
      expect(
        (await service.owner.ownerProposalReceipt('reject-1'))!.records,
        isEmpty,
      );
      await expectLater(
        decide(
          command('import-1', rejected, ProposalKind.addition),
          () async {},
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'operation_conflict',
          ),
        ),
      );
    },
  );
  test(
    'modification and deletion share each original content transaction',
    () async {
      final session = service.agent.openSession('合成聊天');
      final item = await service.owner.createInformation('合成资料', '', [
        const FieldInput('字段', '', '原值'),
      ]);
      final update = await service.agent.submitUpdate(
        session,
        UpdateInput(item.id, 1, [
          FieldChange.correct(item.fields.single.id, '新值'),
        ]),
      );
      final changed = await decide(
        command('update-1', update, ProposalKind.modification),
        () async {
          await service.owner.confirmUpdate(update, 1);
        },
      );
      expect(changed.records.single.version, 2);
      final deletion = await service.agent.submitDelete(session, item.id, 2);
      final deleted = await decide(
        command('delete-1', deletion, ProposalKind.deletion),
        () async {
          await service.owner.confirmDelete(deletion, 1);
        },
      );
      expect(deleted.records.single.recycleId, isNotEmpty);
      expect(service.owner.information, isEmpty);
      await close();
      await open();
      expect(
        (await service.owner.ownerProposalReceipt(
          'update-1',
        ))!.records.single.version,
        2,
      );
      expect(
        (await service.owner.ownerProposalReceipt(
          'delete-1',
        ))!.records.single.recycleId,
        deleted.records.single.recycleId,
      );
    },
  );
  test(
    'failed receipt commit rolls back imported content and proposal state',
    () async {
      final session = service.agent.openSession('合成聊天');
      final id = await addition(session);
      final db = sqlite3.open('${root.path}/library.db');
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute(
        "CREATE TRIGGER fail_proposal_receipt BEFORE INSERT ON owner_proposal_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
      );
      db.close();
      await expectLater(
        decide(command('fail-1', id, ProposalKind.addition), () async {
          await service.owner.confirmImport(
            id,
            1,
            service.owner.importProposals.single.items,
          );
        }),
        throwsA(isA<StorageFailure>()),
      );
      expect(service.owner.information, isEmpty);
      expect(
        service.owner.importProposals.single.state,
        ImportProposalState.pending,
      );
      expect(await service.owner.ownerProposalReceipt('fail-1'), isNull);
      await close();
      await open();
      expect(service.owner.information, isEmpty);
      expect(
        service.owner.importProposals.single.state,
        ImportProposalState.pending,
      );
    },
  );
}
