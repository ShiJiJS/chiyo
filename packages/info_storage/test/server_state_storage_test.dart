import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  test(
    'online cache boundary configurations open and persist normally',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-cache-budget-');
      try {
        for (final budget in [32, 512]) {
          final keys = TestKeyStore();
          var repo = await EncryptedInformationRepository.openOnline(
            '${root.path}/$budget',
            keys,
            readCacheMiB: budget,
          );
          final initial = await repo.openServerState();
          await repo.commitServerState(initial, {'value': budget});
          await repo.close();
          repo = await EncryptedInformationRepository.openOnline(
            '${root.path}/$budget',
            keys,
            readCacheMiB: budget,
          );
          expect((await repo.openServerState()).payload['value'], budget);
          await repo.close();
        }
        for (final invalid in [0, 31, 513]) {
          expect(
            () => EncryptedInformationRepository.openOnline(
              '${root.path}/invalid',
              TestKeyStore(),
              readCacheMiB: invalid,
            ),
            throwsArgumentError,
          );
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('online unchanged reads do not commit SQLCipher pages', () async {
    final root = await Directory.systemTemp.createTemp('chiyo-no-write-');
    final keys = TestKeyStore();
    final repo = await EncryptedInformationRepository.openOnline(
      root.path,
      keys,
    );
    final runtime = await OnlineInformationRuntime.open(repository: repo);
    final observer = sql.sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    observer.execute('PRAGMA key = "x\'$hex\'"');
    int version() =>
        observer.select('PRAGMA data_version').single.values.single as int;
    try {
      final initial = version();
      for (var i = 0; i < 5; i++) {
        await repo.openServerState();
        await runtime.run(() {});
        expect(version(), initial);
      }
      await runtime.run(
        () => runtime.service.owner.createInformation('New item', '', [
          const FieldInput('Body', '', 'durable value'),
        ]),
      );
      expect(version(), greaterThan(initial));
    } finally {
      observer.close();
      await runtime.close();
      await repo.close();
      await root.delete(recursive: true);
    }
  });

  test(
    'encrypted host state survives reopen and rejects stale writers',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-server-state-');
      addTearDown(() => root.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(root.path, keys);
      late ServerStateSnapshot saved;
      try {
        final initial = await repo.openServerState();
        final mutable = <String, Object?>{
          'devices': [
            {'token': 'PRIVATE_SYNTHETIC_DEVICE_TOKEN'},
          ],
        };
        saved = await repo.commitServerState(initial, mutable);
        (mutable['devices'] as List).clear();
        expect(saved.payload['devices'], hasLength(1));
        await expectLater(
          repo.commitServerState(initial, {}),
          throwsA(
            isA<AccessFailure>().having(
              (e) => e.status,
              'status',
              'server_state_changed',
            ),
          ),
        );
        expect(
          () => (saved.payload['devices'] as List).clear(),
          throwsUnsupportedError,
        );
      } finally {
        await repo.close();
      }
      expect(
        String.fromCharCodes(
          await File('${root.path}/library.db').readAsBytes(),
        ).contains('PRIVATE_SYNTHETIC_DEVICE_TOKEN'),
        isFalse,
      );
      repo = await EncryptedInformationRepository.open(root.path, keys);
      try {
        final reopened = await repo.openServerState();
        expect(reopened.generation, saved.generation);
        expect(reopened.revision, saved.revision);
        expect(reopened.payload, saved.payload);
        final attempts = await Future.wait([
          repo
              .commitServerState(reopened, {'winner': 1})
              .then((_) => true, onError: (Object e) => false),
          repo
              .commitServerState(reopened, {'winner': 2})
              .then((_) => true, onError: (Object e) => false),
        ]);
        expect(attempts.where((v) => v), hasLength(1));
        expect((await repo.openServerState()).revision, reopened.revision + 1);
      } finally {
        await repo.close();
      }
    },
  );

  test(
    'portable restore discards both source and recipient active state',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-server-state-restore-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
      );
      late String recoveryKey;
      final archive = '${root.path}/backup';
      final service = InformationService(repository: source);
      try {
        await service.owner.createInformation('Synthetic item', '', [
          const FieldInput('Body', '', 'portable content'),
        ]);
        final state = await source.openServerState();
        await source.commitServerState(state, {'token': 'SOURCE_ACTIVE_TOKEN'});
        recoveryKey = await enableTestBackups(source.backups);
        await source.backups.exportTo(archive);
      } finally {
        await service.close();
        await source.close();
      }
      final keys = TestKeyStore();
      var recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        keys,
      );
      late String newGeneration;
      try {
        final initial = await recipient.openServerState();
        final previous = await recipient.commitServerState(initial, {
          'token': 'RECIPIENT_OLD_TOKEN',
        });
        expect(await recipient.backups.recipientEmpty(), isTrue);
        await expectLater(
          recipient.backups.restoreFrom(archive, 'invalid-recovery-key'),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          (await recipient.openServerState()).generation,
          previous.generation,
        );
        expect((await recipient.openServerState()).payload, previous.payload);
        await recipient.backups.restoreFrom(archive, recoveryKey);
        await expectLater(
          recipient.commitServerState(previous, {'token': 'REPLAYED'}),
          throwsA(isA<AccessFailure>()),
        );
        final reset = await recipient.openServerState();
        expect(reset.generation, isNot(previous.generation));
        expect(reset.payload, isEmpty);
        expect(reset.revision, 0);
        newGeneration = reset.generation;
        await expectLater(
          recipient.commitServerState(previous, {}),
          throwsA(isA<AccessFailure>()),
        );
      } finally {
        await recipient.close();
      }
      recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        keys,
      );
      try {
        expect((await recipient.openServerState()).generation, newGeneration);
        expect((await recipient.openServerState()).payload, isEmpty);
        expect(recipient.items.single.fields.single.value, 'portable content');
      } finally {
        await recipient.close();
      }
    },
  );
}
