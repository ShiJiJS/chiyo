import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';
import '../../info_core/test_support/native_fill.dart' show nativeTargetFixture;

const _device = 'AAAAAAAAAAAAAAAAAAAAAA';
CredentialBatchInput _input(String id, {String? nativeKind}) =>
    CredentialBatchInput.fromJson({
      'protocolVersion': 3,
      'purpose': 'Synthetic login',
      'agentName': 'Trial Agent',
      'externalChatId': 'synthetic-chat',
      'items': [
        {
          'credentialId': id,
          'destination': nativeKind != null
              ? {
                  'via': 'native',
                  'target': nativeTargetFixture(controlKind: nativeKind),
                }
              : {
                  'via': 'ego',
                  'target': {
                    'provider': 'ego',
                    'instanceId': 'synthetic-browser',
                    'space': 7,
                    'pageId': 'p1',
                    'url': 'https://example.test/login',
                    'form': '#login',
                    'field': '#password',
                    'structureDigest': 'a' * 64,
                  },
                },
        },
      ],
    });
Future<ManagedCredential> _credential(InformationService service) async {
  final c = await service.owner.createStringCredential(
    name: 'Synthetic login',
    publicPurpose: 'Synthetic service',
    secret: 'PRIVATE-BATCH-PASSWORD',
  );
  return service.owner.updateCredentialMetadata(
    c.id,
    c.revision,
    name: c.name,
    publicPurpose: c.publicPurpose,
    privateNote: '',
    suggestedBinding: c.suggestedBinding,
    discoverable: true,
  );
}

void main() {
  for (final kind in [
    null,
    'appkit_secure_text',
    'macos_ax_password',
    'windows_uia_password',
  ]) {
    _tests(kind);
  }
}

void _tests(String? nativeKind) {
  final native = nativeKind != null;
  final v2 = native && nativeKind != 'appkit_secure_text';
  test(
    '${native ? '$nativeKind ' : ''}encrypted batches preserve live server grants, not an interrupted input capability',
    () async {
      final root = await Directory.systemTemp.createTemp('encrypted-batches-');
      addTearDown(() => root.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.openOnline(
        root.path,
        keys,
      );
      var runtime = await OnlineInformationRuntime.open(repository: repo);
      final c = await runtime.run(() => _credential(runtime.service));
      final session = await runtime.run(
        () => runtime.service.agent.openSession('Synthetic chat'),
      );
      final r = await runtime.run(
        () => runtime.service.agent.requestCredentialBatch(
          session,
          _device,
          _input(c.id, nativeKind: nativeKind),
          operationId: 'submit-1',
        ),
      );
      final approved = await runtime.run(
        () => runtime.service.owner.decideCredentialBatch(
          r.id,
          operationId: 'approve-1',
          revision: r.revision,
          approvedItems: ['b1'],
        ),
      );
      final started = await runtime.run(
        () => runtime.service.agent.beginCredentialBatchOperation(
          session,
          _device,
          r.id,
          operationId: 'fill-1',
        ),
      );
      await runtime.close();
      await repo.close();
      final database = sqlite.sqlite3.open('${root.path}/library.db');
      final keyHex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      database.execute('PRAGMA key = "x\'$keyHex\'"');
      expect(
        database.select('PRAGMA user_version').single.values.single,
        v2
            ? 70
            : native
            ? 69
            : 65,
      );
      if (v2) {
        database.execute('PRAGMA user_version=69');
        database.execute('UPDATE library_format SET version=69');
      }
      database.close();
      if (v2) {
        await expectLater(
          EncryptedInformationRepository.openOnline(root.path, keys),
          throwsA(
            isA<StorageFailure>().having(
              (error) => error.code,
              'code',
              'unsupported_schema',
            ),
          ),
        );
        final repair = sqlite.sqlite3.open('${root.path}/library.db');
        repair.execute('PRAGMA key = "x\'$keyHex\'"');
        repair.execute('PRAGMA user_version=70');
        repair.execute('UPDATE library_format SET version=70');
        repair.close();
      }
      repo = await EncryptedInformationRepository.openOnline(root.path, keys);
      runtime = await OnlineInformationRuntime.open(repository: repo);
      addTearDown(() async {
        await runtime.close();
        await repo.close();
      });
      final status = runtime.service.agent.credentialBatchStatus(
        session,
        _device,
        r.id,
      );
      expect((status['items'] as List).single['grantState'], 'available');
      expect(
        repo.credentialBatches.single.items.single.expiresAt,
        approved.items.single.expiresAt,
      );
      expect(
        repo.credentialBatchOperations.single.state,
        CredentialBatchOperationState.unknown,
      );
      final repeat = await runtime.run(
        () => runtime.service.agent.beginCredentialBatchOperation(
          session,
          _device,
          r.id,
          operationId: 'fill-1',
        ),
      );
      expect(repeat.privateProof, isNull);
      expect(repeat.operation.state, CredentialBatchOperationState.unknown);
      await expectLater(
        runtime.run(
          () => runtime.service.agent.claimCredentialBatchMaterials(
            _device,
            started.privateProof!,
            {'b1': r.items.single.destination},
          ),
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      for (final file in root.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(await file.readAsBytes()),
          isNot(contains('PRIVATE-BATCH-PASSWORD')),
        );
      }
    },
  );

  test(
    '${native ? '$nativeKind ' : ''}portable backup keeps decided batch history, drops pending work, and restores no usable grant',
    () async {
      final root = await Directory.systemTemp.createTemp('batch-backup-');
      addTearDown(() => root.delete(recursive: true));
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
      );
      final service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
      });
      final c = await _credential(service);
      final session = service.agent.openSession('Synthetic chat');
      final r = await service.agent.requestCredentialBatch(
        session,
        _device,
        _input(c.id, nativeKind: nativeKind),
        operationId: 'submit-1',
      );
      await service.owner.decideCredentialBatch(
        r.id,
        operationId: 'approve-1',
        revision: r.revision,
        approvedItems: ['b1'],
      );
      await service.agent.requestCredentialBatch(
        session,
        _device,
        _input(c.id, nativeKind: nativeKind),
        operationId: 'pending-2',
      );
      final operation = await service.agent.beginCredentialBatchOperation(
        session,
        _device,
        r.id,
        operationId: 'fill-1',
      );
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/history.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(path));
      expect(
        service.agent.credentialBatchStatus(session, _device, r.id)['status'],
        'approved',
      );
      expect(repo.credentialBatches, hasLength(2));
      final preview = await repo.backups.inspect(path, recovery);
      expect(
        preview.formatVersion,
        v2
            ? 31
            : native
            ? 30
            : 28,
      );
      if (v2) {
        final keyHex = base64Url
            .decode(recovery.substring('aim-recovery-v1:'.length))
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        final archive = sqlite.sqlite3.open(path);
        archive.execute('PRAGMA key = "x\'$keyHex\'"');
        final original =
            archive
                    .select('SELECT payload FROM backup_snapshot')
                    .single['payload']
                as String;
        archive.execute('UPDATE backup_snapshot SET payload=?', [
          jsonEncode({...jsonDecode(original) as Map, 'version': 30}),
        ]);
        archive.close();
        await expectLater(
          repo.backups.inspect(path, recovery),
          throwsA(
            isA<StorageFailure>().having(
              (error) => error.code,
              'code',
              'invalid_backup',
            ),
          ),
        );
        final repair = sqlite.sqlite3.open(path);
        repair.execute('PRAGMA key = "x\'$keyHex\'"');
        repair.execute('UPDATE backup_snapshot SET payload=?', [original]);
        repair.close();
      }
      expect(preview.credentialUseHistoryCount, 1);
      expect(preview.credentialExecutionCount, 1);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
      );
      final restored = InformationService(repository: target);
      addTearDown(() async {
        await restored.close();
        await target.close();
      });
      await restored.owner.restoreLibrary(
        () => target.backups.restoreFrom(path, recovery),
      );
      expect(target.credentialBatches, hasLength(1));
      final history = target.credentialBatches.single;
      expect(history.id, r.id);
      expect(history.archived, true);
      expect(
        restored.owner.credentialBatchItemState(history, history.items.single),
        'revoked',
      );
      expect(
        target.credentialBatchOperations.single.state,
        CredentialBatchOperationState.unknown,
      );
      expect(
        jsonEncode(history.toJson()),
        isNot(contains(operation.privateProof!)),
      );
      final newSession = restored.agent.openSession('Synthetic chat');
      await expectLater(
        restored.agent.beginCredentialBatchOperation(
          newSession,
          _device,
          r.id,
          operationId: 'after-restore',
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
}
