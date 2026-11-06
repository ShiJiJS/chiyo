import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/ssh_session_fixture.dart'
    show SshSessionFixture;
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late SshSessionFixture f;
  var now = DateTime.utc(2026, 11, 7);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ssh-session-sql-');
    keys = TestKeyStore();
    now = DateTime.utc(2026, 11, 7);
    repo = await EncryptedInformationRepository.open(
      '${root.path}/data',
      keys,
      clock: () => now,
    );
    f = await SshSessionFixture.create(clock: () => now, repository: repo);
  });
  tearDown(() async {
    await f.service.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  T sql<T>(T Function(Database) action) {
    final db = sqlite3.open('${root.path}/data/library.db');
    try {
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      return action(db);
    } finally {
      db.close();
    }
  }

  int format() => sql(
    (db) =>
        db.select('SELECT version FROM library_format').single['version']
            as int,
  );
  Future<void> approve() => f.service.owner.decideCredentialUse(
    f.request.id,
    approveCredential: true,
    lifetime: null,
  );

  test(
    'session decision and format marker roll back together; encrypted reopen preserves history but never live permission',
    () async {
      final oldFormat = format();
      expect(oldFormat, lessThan(52));
      sql(
        (db) => db.execute(
          "CREATE TRIGGER fail_session_decision BEFORE INSERT ON credential_runtime_requests BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
        ),
      );
      await expectLater(
        approve(),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'audit_unavailable',
          ),
        ),
      );
      expect(format(), oldFormat);
      expect(f.service.owner.credentialUseRequests.single.state, 'pending');
      sql((db) => db.execute('DROP TRIGGER fail_session_decision'));
      await approve();
      expect(format(), 52);
      now = now.add(const Duration(days: 2));
      final claim = await f.begin('operation-one');
      await f.service.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: claim.execution.id,
          executionCapability: claim.material!.executionCapability,
          state: 'start_failed',
          errorCode: 'process_start_failed',
          finishedAt: now,
        ),
      );
      await f.service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
        clock: () => now,
      );
      final service = InformationService(repository: repo, clock: () => now);
      addTearDown(service.close);
      final saved = service.owner.credentialUseRequests.single;
      expect(saved.credentialValidity, CredentialUseValidity.session);
      expect(saved.credentialExpiresAt, isNull);
      expect(saved.invalidatedCode, 'grant_revoked');
      expect(service.owner.credentialGrantState(saved), 'revoked');
      expect(service.owner.credentialExecutions.single.state, 'start_failed');
      await expectLater(
        service.agent.beginCredentialUseOperation(
          f.session,
          f.operation('new-after-restart'),
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(format(), 52);
    },
  );

  test(
    'full backup uses an explicit session format, restores only history and rejects relabelled or malformed records',
    () async {
      await approve();
      final recovery = await enableTestBackups(repo.backups),
          path = '${root.path}/session.aimbackup';
      await f.service.owner.exportLibrary(() => repo.backups.exportTo(path));
      final contents = await repo.backups.inspect(path, recovery);
      expect(contents.formatVersion, 22);
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
        clock: () => now,
      );
      addTearDown(target.close);
      await target.backups.restore(contents);
      final service = InformationService(repository: target);
      addTearDown(service.close);
      final history = service.owner.credentialUseRequests.single;
      expect(history.credentialValidity, CredentialUseValidity.session);
      expect(history.credentialExpiresAt, isNull);
      expect(history.restoredAt, isNotNull);
      expect(service.owner.credentialGrantState(history), 'revoked');
      final db = sqlite3.open(path);
      try {
        final hex = base64Url
            .decode(recovery.substring('aim-recovery-v1:'.length))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$hex\'"');
        final original =
            jsonDecode(
                  db
                          .select('SELECT payload FROM backup_snapshot')
                          .single['payload']
                      as String,
                )
                as Map<String, dynamic>;
        final lower = {...original, 'version': 21};
        db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(lower)]);
        await expectLater(
          repo.backups.inspect(path, recovery),
          throwsA(isA<StorageFailure>()),
        );
        final rows =
            (original['tables'] as Map)['credential_use_requests'] as List;
        final row = rows.single as Map;
        final payload =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        row['payload'] = jsonEncode({
          ...payload,
          'credentialValidity': 'forever',
        });
        db.execute('UPDATE backup_snapshot SET payload=?', [
          jsonEncode(original),
        ]);
        await expectLater(
          repo.backups.inspect(path, recovery),
          throwsA(isA<StorageFailure>()),
        );
      } finally {
        db.close();
      }
    },
  );

  test(
    'session facts with a lowered format marker are rejected before rewriting runtime history',
    () async {
      await approve();
      await f.service.close();
      await repo.close();
      sql((db) {
        db.execute('UPDATE library_format SET version=51');
        db.execute('PRAGMA user_version=51');
      });
      await expectLater(
        EncryptedInformationRepository.open('${root.path}/data', keys),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_schema',
          ),
        ),
      );
      expect(
        sql(
          (db) => db
              .select('SELECT payload FROM credential_runtime_requests')
              .single['payload'],
        ),
        contains('"credentialValidity":"session"'),
      );
    },
  );
}
