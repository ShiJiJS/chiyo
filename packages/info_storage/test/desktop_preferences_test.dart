import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  final now = DateTime.utc(2026, 11, 1);
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
    await service.owner.history();
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  DesktopPreferences desired({int version = 2, int days = 90}) =>
      DesktopPreferences(
        version: version,
        dark: true,
        notifications: false,
        requestMinutes: 15,
        retentionDays: days,
        background: false,
      );
  Future<DesktopPreferencesReceipt> save({
    String id = 'settings-1',
    int version = 1,
    int days = 90,
    DesktopRetentionPlan? plan,
    String? digest,
  }) => service.owner.saveDesktopPreferences(
    operationId: id,
    commandDigest: digest ?? 'a' * 64,
    expectedVersion: version,
    desired: desired(version: version + 1, days: days),
    retention: plan,
  );
  Future<void> history(String id) => repo.saveRequestHistory(
    RequestHistory(
      id: id,
      sessionId: 'ended-session',
      chatLabel: '合成历史',
      purpose: '合成用途',
      createdAt: now.subtract(const Duration(days: 50)),
      requestExpiresAt: now.subtract(const Duration(days: 50)),
      recordedAt: now.subtract(const Duration(days: 50)),
      state: AccessRequestState.denied,
      fields: const [],
    ),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('desktop-preferences-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  test(
    'legacy duration survives unrelated changes and exact replay without permitting a new non-preset duration',
    () async {
      final owner = service.owner;
      DesktopPreferences values(int version, int minutes) => DesktopPreferences(
        version: version,
        dark: true,
        notifications: false,
        requestMinutes: minutes,
        retentionDays: 90,
        background: false,
      );
      Future<DesktopPreferencesReceipt> write(
        String id,
        int expected,
        int minutes,
      ) => owner.saveDesktopPreferences(
        operationId: id,
        commandDigest: 'c' * 64,
        expectedVersion: expected,
        desired: values(expected + 1, minutes),
      );
      await expectLater(
        write('arbitrary', 1, 47),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'invalid_preferences',
          ),
        ),
      );
      await owner.setRequestLifetime(const Duration(minutes: 47));
      await write('legacy', 1, 47);
      await write('preset', 2, 60);
      expect((await write('legacy', 1, 47)).preferences.requestMinutes, 47);
      expect(owner.requestLifetime, const Duration(minutes: 60));
      await close();
      await open();
      expect(
        (await service.owner.desktopPreferencesReceipt(
          'legacy',
        ))!.preferences.requestMinutes,
        47,
      );
      expect(service.owner.requestLifetime, const Duration(minutes: 60));
    },
  );
  test(
    'all real settings and exact receipt survive independent reopen',
    () async {
      final receipt = await save();
      expect(receipt.preferences.settings, desired().settings);
      expect(service.owner.notificationsEnabled, isFalse);
      expect(service.owner.requestLifetime, const Duration(minutes: 15));
      expect(service.owner.auditRetentionDays, 90);
      await close();
      await open();
      expect(service.owner.desktopPreferences.settings, desired().settings);
      expect(
        (await service.owner.desktopPreferencesReceipt(
          'settings-1',
        ))!.commandDigest,
        'a' * 64,
      );
      expect((await save()).preferences.version, 2);
      await expectLater(
        save(digest: 'b' * 64),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'operation_conflict',
          ),
        ),
      );
      await expectLater(
        save(id: 'stale'),
        throwsA(
          isA<AccessFailure>().having((e) => e.status, 'status', 'conflict'),
        ),
      );
    },
  );
  test(
    'shortening requires exact current cleanup and commits it with preferences',
    () async {
      await history('old-1');
      await expectLater(
        save(days: 30),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'retention_changed',
          ),
        ),
      );
      final plan = await service.owner.previewDesktopRetention(30);
      expect(plan.cleanup.requests, 1);
      await history('old-2');
      await expectLater(
        save(days: 30, plan: plan),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'retention_changed',
          ),
        ),
      );
      expect(repo.requestHistory.length, 2);
      final fresh = await service.owner.previewDesktopRetention(30);
      await save(days: 30, plan: fresh);
      expect(repo.requestHistory, isEmpty);
      await close();
      await open();
      expect(repo.requestHistory, isEmpty);
      expect(service.owner.auditRetentionDays, 30);
      expect(
        (await service.owner.desktopPreferencesReceipt(
          'settings-1',
        ))!.preferences.retentionDays,
        30,
      );
    },
  );
  test('failed receipt insert rolls back cleanup and every preference', () async {
    await history('old-1');
    final plan = await service.owner.previewDesktopRetention(30);
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    db.execute(
      "CREATE TRIGGER fail_preferences BEFORE INSERT ON desktop_preference_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
    );
    db.close();
    await expectLater(
      save(days: 30, plan: plan),
      throwsA(isA<StorageFailure>()),
    );
    expect(service.owner.desktopPreferences.version, 1);
    expect(service.owner.desktopPreferences.dark, isFalse);
    expect(service.owner.auditRetentionDays, 90);
    expect(repo.requestHistory.single.id, 'old-1');
    expect(await service.owner.desktopPreferencesReceipt('settings-1'), isNull);
    await close();
    await open();
    expect(service.owner.desktopPreferences.version, 1);
    expect(repo.requestHistory.single.id, 'old-1');
  });
  test(
    'empty recipient with local preference receipts can restore and invalidates them',
    () async {
      final sourceRepo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
        clock: () => now,
      );
      final sourceService = InformationService(
        repository: sourceRepo,
        clock: () => now,
      );
      await sourceService.owner.createInformation('合成恢复资料', '', [
        const FieldInput('字段', '', '合成正文'),
      ]);
      final recovery = await enableTestBackups(sourceRepo.backups);
      final backup = '${root.path}/synthetic.aimbackup';
      await sourceRepo.backups.exportTo(backup);
      await sourceService.close();
      await sourceRepo.close();
      await save();
      await repo.backups.restoreFrom(backup, recovery);
      expect(service.owner.information.single.name, '合成恢复资料');
      await expectLater(
        service.owner.desktopPreferencesReceipt('settings-1'),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_changed',
          ),
        ),
      );
    },
  );
}
