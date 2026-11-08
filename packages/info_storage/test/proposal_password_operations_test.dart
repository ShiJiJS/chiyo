import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/credential_import_fixture.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late OnlineInformationRuntime runtime;
  late String proposalId, session;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open('${root.path}/data', keys);
    runtime = await OnlineInformationRuntime.open(repository: repo);
    configureCredentialImports(runtime.service);
  }

  Future<void> close() async {
    await runtime.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'proposal-password-operation-',
    );
    keys = TestKeyStore();
    await open();
    session = runtime.service.agent.openSession('Synthetic password chat');
    proposalId = await runtime.run(
      () => runtime.service.agent.submitImport(session, [
        credentialInput(
          'first',
          'accountPassword',
          CredentialImportInput.owner(account: 'synthetic-user'),
        ),
        credentialInput(
          'second',
          'accountPassword',
          CredentialImportInput.owner(account: 'another-user'),
        ),
      ]),
    );
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Matcher fails(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));

  test(
    'whole password batch has a durable private retry receipt, never admits records or repeats the revision',
    () async {
      const values = {
        'first': 'SYNTHETIC_PRIVATE_FIRST',
        'second': 'SYNTHETIC_PRIVATE_SECOND',
      };
      await expectLater(
        runtime.run(
          () => runtime.service.owner.fillImportCredentialsOperation(
            proposalId,
            1,
            {'first': values['first']!, 'second': ''},
            'invalid',
          ),
        ),
        fails('invalid_credential_content'),
      );
      expect(runtime.service.owner.importProposals.single.version, 1);
      expect(
        await runtime.run(
          () => runtime.service.owner.importPasswordFillReceipt('invalid'),
        ),
        isNull,
      );
      final receipt = await runtime.run(
        () => runtime.service.owner.fillImportCredentialsOperation(
          proposalId,
          1,
          values,
          'fill',
        ),
      );
      expect(receipt.resultingVersion, 2);
      expect(
        runtime.service.owner.importProposals.single.items.every(
          (i) => i.credential!.ready,
        ),
        true,
      );
      expect(runtime.service.owner.credentials, isEmpty);
      expect(repo.credentialMaterials, isEmpty);
      expect(
        jsonEncode(receipt.toPrivateJson()),
        isNot(contains(values['first'])),
      );
      expect(
        jsonEncode(runtime.service.agent.importStatus(session, proposalId)),
        isNot(contains(values['first'])),
      );
      await close();
      await open();
      expect(
        (await runtime.run(
          () => runtime.service.owner.importPasswordFillReceipt('fill'),
        ))!.toPrivateJson(),
        receipt.toPrivateJson(),
      );
      expect(
        (await runtime.run(
          () => runtime.service.owner.fillImportCredentialsOperation(
            proposalId,
            1,
            values,
            'fill',
          ),
        )).toPrivateJson(),
        receipt.toPrivateJson(),
      );
      expect(runtime.service.owner.importProposals.single.version, 2);
      await expectLater(
        runtime.run(
          () => runtime.service.owner.fillImportCredentialsOperation(
            proposalId,
            1,
            {...values, 'first': 'DIFFERENT_PRIVATE_VALUE'},
            'fill',
          ),
        ),
        fails('operation_conflict'),
      );
      expect(
        await runtime.run(
          () => runtime.service.owner.readImportPasswordForOwner(
            proposalId,
            2,
            'first',
          ),
        ),
        values['first'],
      );
      await runtime.run(
        () => runtime.service.owner.confirmImport(
          proposalId,
          2,
          runtime.service.owner.importProposals.single.items,
        ),
      );
      expect(runtime.service.owner.credentials, hasLength(2));
      expect(
        (await runtime.run(
          () => runtime.service.owner.fillImportCredentialsOperation(
            proposalId,
            1,
            values,
            'fill',
          ),
        )).resultingVersion,
        2,
      );
      expect(runtime.service.owner.importProposals.single.version, 3);
      expect(runtime.service.owner.credentialUseRequests, isEmpty);
      await expectLater(
        runtime.run(
          () => runtime.service.owner.readImportPasswordForOwner(
            proposalId,
            3,
            'first',
          ),
        ),
        fails('proposal_changed'),
      );
    },
  );

  test(
    'SQL failure of the private receipt rolls back every password and the proposal revision',
    () async {
      final db = sqlite3.open('${root.path}/data/library.db');
      final key = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$key\'"');
      try {
        db.execute(
          'CREATE TRIGGER reject_password_fill BEFORE UPDATE ON server_runtime_state '
          'WHEN instr(NEW.payload,\'atomic-failure\')>0 BEGIN SELECT RAISE(ABORT,\'synthetic write failure\'); END',
        );
        await expectLater(
          runtime.run(
            () => runtime.service.owner.fillImportCredentialsOperation(
              proposalId,
              1,
              {'first': 'SYNTHETIC_FIRST', 'second': 'SYNTHETIC_SECOND'},
              'atomic-failure',
            ),
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(runtime.service.owner.importProposals.single.version, 1);
        expect(
          runtime.service.owner.importProposals.single.items.every(
            (i) => !i.credential!.ready,
          ),
          true,
        );
        expect(
          await runtime.run(
            () => runtime.service.owner.importPasswordFillReceipt(
              'atomic-failure',
            ),
          ),
          isNull,
        );
      } finally {
        db.execute('DROP TRIGGER IF EXISTS reject_password_fill');
        db.close();
      }
      await close();
      await open();
      expect(runtime.service.owner.importProposals.single.version, 1);
      final result = await runtime.run(
        () => runtime.service.owner.fillImportCredentialsOperation(
          proposalId,
          1,
          {'first': 'SYNTHETIC_FIRST', 'second': 'SYNTHETIC_SECOND'},
          'atomic-failure',
        ),
      );
      expect(result.resultingVersion, 2);
    },
  );

  test(
    'portable backup omits pending private inputs and server password operation receipts',
    () async {
      await runtime.run(
        () => runtime.service.owner.fillImportCredentialsOperation(
          proposalId,
          1,
          {'first': 'SYNTHETIC_FIRST', 'second': 'SYNTHETIC_SECOND'},
          'private-fill',
        ),
      );
      final recovery = await enableTestBackups(repo.backups);
      final archive = '${root.path}/portable.aimbackup';
      await repo.backups.exportTo(archive);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
      );
      try {
        await target.backups.restoreFrom(archive, recovery);
        final restored = await OnlineInformationRuntime.open(
          repository: target,
        );
        try {
          expect(
            await restored.run(
              () => restored.service.owner.importPasswordFillReceipt(
                'private-fill',
              ),
            ),
            isNull,
          );
        expect(restored.service.owner.importProposals, isEmpty);
        expect(restored.service.owner.credentials, isEmpty);
        } finally {
          await restored.close();
        }
      } finally {
        await target.close();
      }
    },
  );
}
