import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'backup_setup.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'one program approval freezes every receiving position, survives reopen, and archives as non-authoritative history',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'program-batch-storage-',
      );
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/source',
        keys,
      );
      var runtime = await OnlineInformationRuntime.open(repository: repo);
      addTearDown(() async {
        await runtime.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final cs = await runtime.run(() async {
        final owner = runtime.service.owner;
        final password = await owner.createStringCredential(
          name: 'Synthetic DB password',
          publicPurpose: '',
          secret: 'NEVER-SAVE-PROGRAM-PASSWORD',
        );
        final file = await owner.createFileCredential(
          name: 'Synthetic client key',
          publicPurpose: '',
          fileName: 'client.key',
          bytes: utf8.encode('NEVER-SAVE-PROGRAM-KEY'),
        );
        return [
          for (final c in [password, file])
            await owner.updateCredentialMetadata(
              c.id,
              c.revision,
              name: c.name,
              publicPurpose: '',
              privateNote: '',
              suggestedBinding: c.suggestedBinding,
              discoverable: true,
            ),
        ];
      });
      const device = 'AAAAAAAAAAAAAAAAAAAAAA';
      final session = await runtime.run(
        () => runtime.service.agent.openSession('Synthetic program chat'),
      );
      final identity = ExecutableIdentity(
        '/execution-device/project-tool',
        100,
        1,
        'sha256:${'a' * 64}',
      );
      CredentialProgramPlan plan({bool invalidEnv = false}) =>
          CredentialProgramPlan.fromJson(
            {
              'executable': identity.path,
              'cwd': '/execution-device/work',
              'argv': [
                'sync',
                {
                  'file': {'credentialId': cs.last.id},
                },
              ],
              'env': {
                'DB_PASSWORD': {
                  'credentialId': invalidEnv ? cs.last.id : cs.first.id,
                },
              },
              'stdin': {'credentialId': cs.first.id},
            },
            allowPortablePaths: true,
          ).resolved(identity, '/execution-device/work');
      final input = CredentialBatchInput.forProgram(
        plan(),
        purpose: 'Synthetic program workflow',
      );
      expect(input.items, hasLength(3));
      expect(
        () => CredentialBatchInput.fromJson(
          Map<String, dynamic>.from(input.toJson()),
        ),
        throwsA(isA<CredentialUseFailure>()),
        reason: 'Fill-only request decoding cannot accept a program.',
      );
      final submitted = await runtime.run(
        () => runtime.service.agent.requestCredentialBatch(
          session,
          device,
          input,
          operationId: 'program-submit',
        ),
      );
      expect(submitted.programPlan, isNotNull);
      expect(
        submitted.programPlan!.bindings.every((b) => b.reference.version == 1),
        true,
      );
      expect(
        submitted.items.first.destination.program!.binding.location,
        'argv[1]',
      );
      expect(
        submitted.items[1].destination.program!.binding.location,
        'env.DB_PASSWORD',
      );
      expect(
        submitted.items.last.destination.program!.binding.location,
        'stdin',
      );
      final original = submitted.toJson();
      expect(
        () => CredentialUseBatch.fromJson({...original}..remove('programPlan')),
        throwsA(isA<CredentialUseFailure>()),
      );
      final broken = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      (((broken['programPlan'] as Map)['env'] as Map)['DB_PASSWORD']
              as Map)['version'] =
          2;
      expect(
        () => CredentialUseBatch.fromJson(broken),
        throwsA(isA<CredentialUseFailure>()),
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.requestCredentialBatch(
            session,
            device,
            CredentialBatchInput.forProgram(
              plan(invalidEnv: true),
              purpose: 'Bad file environment',
            ),
            operationId: 'bad-program',
          ),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'invalid_reference',
          ),
        ),
      );
      await runtime.run(
        () => runtime.service.owner.decideCredentialBatch(
          submitted.id,
          operationId: 'program-approve',
          revision: 1,
          approvedItems: ['b1', 'b2'],
        ),
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.beginCredentialBatchOperation(
            session,
            device,
            submitted.id,
            operationId: 'wrong-fill-route',
          ),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_receiver',
          ),
        ),
      );
      expect(repo.credentialBatchOperations, isEmpty);
      await runtime.close();
      await repo.close();
      final db = sqlite.sqlite3.open('${root.path}/source/library.db');
      final keyHex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$keyHex\'"');
      expect(db.select('PRAGMA user_version').single.values.single, 67);
      db.close();
      repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/source',
        keys,
      );
      runtime = await OnlineInformationRuntime.open(repository: repo);
      final repeated = await runtime.run(
        () => runtime.service.agent.requestCredentialBatch(
          session,
          device,
          input,
          operationId: 'program-submit',
        ),
      );
      expect(repeated.id, submitted.id);
      expect(repo.credentialBatches, hasLength(1));
      final status = runtime.service.agent.credentialBatchStatus(
        session,
        device,
        submitted.id,
      );
      expect((status['items'] as List).map((i) => (i as Map)['grantState']), [
        'available',
        'available',
        'denied',
      ]);
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/program-history.aimbackup';
      await runtime.run(
        () => runtime.service.owner.exportLibrary(
          () => repo.backups.exportTo(path),
        ),
      );
      expect((await repo.backups.inspect(path, recovery)).formatVersion, 29);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      final restored = InformationService(repository: target);
      try {
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom(path, recovery),
        );
        final history = target.credentialBatches.single;
        expect(history.archived, true);
        expect(history.programPlan!.toJson(), repeated.programPlan!.toJson());
        expect(
          restored.owner.credentialBatchItemState(history, history.items.first),
          'revoked',
        );
        expect(
          jsonEncode(history.toJson()),
          isNot(contains('NEVER-SAVE-PROGRAM')),
        );
      } finally {
        await restored.close();
        await target.close();
      }
      for (final file in Directory(
        '${root.path}/source',
      ).listSync().whereType<File>()) {
        expect(
          String.fromCharCodes(await file.readAsBytes()),
          isNot(contains('NEVER-SAVE-PROGRAM')),
        );
      }
    },
  );
}
