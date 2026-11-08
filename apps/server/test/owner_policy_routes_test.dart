import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_workspace/settings_transport.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/owner_reply_proxy.dart';

Future<WorkspaceServerPolicy> read(DeviceCredentialFixture f) async =>
    WorkspaceServerPolicy.fromJson(
      await f.owner.request('GET', '/v1/owner/settings'),
    );
WorkspaceServerPolicyChange command(
  WorkspaceServerPolicy p,
  String id, {
  int request = 60,
  int? retention,
  String? token,
}) => WorkspaceServerPolicyChange(
  operationId: id,
  commandDigest: 'a' * 64,
  generation: p.generation,
  expectedVersion: p.version,
  requestMinutes: request,
  retentionDays: retention ?? p.retentionDays,
  retentionToken: token,
);
Future<WorkspaceServerPolicyReceipt> save(
  DeviceCredentialFixture f,
  WorkspaceServerPolicyChange c,
) async => WorkspaceServerPolicyReceipt.fromJson(
  await f.owner.request('POST', '/v1/owner/settings/changes', c.json),
);
String query(WorkspaceServerPolicyChange c) =>
    '/v1/owner/settings/operations/${c.generation}/${c.operationId}';
Matcher fails(String code) =>
    throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', code));
Future<void> sql(DeviceCredentialFixture f, String statement) async {
  final key = await MountedDatabaseKeyStore(
    '${f.root.path}/secrets/database.key',
  ).read();
  final db = sqlite3.open('${f.root.path}/data/library.db');
  try {
    db.execute(
      'PRAGMA key = "x\'${key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
    );
    db.execute(statement);
  } finally {
    db.close();
  }
}

void main() {
  test(
    'an existing legacy request duration is preserved for unrelated policy edits, but is not allowed as a new arbitrary duration',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final initial = await read(f);
      await expectLater(
        save(f, command(initial, 'new-arbitrary', request: 47)),
        fails('invalid_preferences'),
      );
      await f.runtime.run(
        () => f.runtime.service.owner.setRequestLifetime(
          const Duration(minutes: 47),
        ),
      );
      final legacy = await read(f);
      expect(legacy.requestMinutes, 47);
      final c = command(legacy, 'keep-legacy', request: 47, retention: 180);
      final result = await save(f, c);
      expect(result.matches(c), isTrue);
      expect((await read(f)).requestMinutes, 47);
      await save(f, command(await read(f), 'new-preset', request: 60));
      expect((await save(f, c)).json, result.json);
      expect((await read(f)).requestMinutes, 60);
    },
  );
  test(
    'shared server policy excludes device appearance, refuses Agent identity and extra local fields, and returns exact receipt through loss and restart',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final old = f.runtime.service.owner.desktopPreferences;
      final p = await read(f);
      expect(p.generation, isNot((await f.repo.openServerState()).generation));
      expect(p.requestMinutes, old.requestMinutes);
      final agent = HttpClient(context: f.trust);
      try {
        for (final path in [
          '/v1/owner/settings',
          '/v1/owner/settings/notification-preview',
        ]) {
          final request = await agent.getUrl(f.owner.address.resolve(path));
          request.headers.set(
            'authorization',
            'Bearer ${f.profiles.first.deviceToken}',
          );
          final response = await request.close();
          expect(response.statusCode, 401);
          await response.drain<void>();
        }
      } finally {
        agent.close(force: true);
      }
      final c = command(p, 'policy-once');
      await expectLater(
        f.owner.request('POST', '/v1/owner/settings/changes', {
          ...c.json,
          'theme': 'dark',
        }),
        fails('invalid_request'),
      );
      expect((await read(f)).version, p.version);
      final proxy = await OwnerReplyProxy.start(
        tls: f.tls,
        trust: f.trust,
        target: () => f.owner.address,
        serverId: f.owner.serverId,
      );
      addTearDown(proxy.close);
      final client = await OwnerClient.connect(
        address: proxy.address,
        token: f.token,
        trust: f.trust,
      );
      addTearDown(client.close);
      proxy.dropNextPath = '/v1/owner/settings/changes';
      await expectLater(
        client.request('POST', '/v1/owner/settings/changes', c.json),
        throwsA(isA<RemoteFailure>()),
      );
      proxy.failGetPrefix = '/v1/owner/settings/operations/';
      await expectLater(
        client.request('GET', query(c)),
        throwsA(isA<RemoteFailure>()),
      );
      await f.reopen();
      proxy.failGetPrefix = null;
      final receipt = WorkspaceServerPolicyReceipt.fromJson(
        await client.request('GET', query(c)),
      );
      expect(receipt.matches(c), isTrue);
      expect(proxy.requests['POST /v1/owner/settings/changes'], 1);
      final current = f.runtime.service.owner.desktopPreferences;
      expect(current.dark, old.dark);
      expect(current.notifications, old.notifications);
      expect(current.background, old.background);
      expect(current.requestMinutes, 60);
      expect((await save(f, c)).json, receipt.json);
      expect((await read(f)).version, p.version + 1);
      await expectLater(
        save(f, command(p, 'policy-once', request: 120)),
        fails('operation_conflict'),
      );
      await expectLater(
        save(f, command(p, 'stale-policy', request: 120)),
        fails('conflict'),
      );
    },
  );

  test(
    'confirmed policy absence is durable and prevents a delayed old command after process reopen',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final p = await read(f);
      final c = command(p, 'late-policy');
      await expectLater(
        f.owner.request('GET', query(c)),
        fails('operation_not_found'),
      );
      await f.reopen();
      await expectLater(save(f, c), fails('not_submitted'));
      expect((await read(f)).json, p.json);
      final next = command(p, 'explicit-new-policy');
      expect((await save(f, next)).matches(next), isTrue);
      final state = jsonEncode((await f.repo.openServerState()).payload);
      expect(state, isNot(contains('desktopDarkAppearance')));
    },
  );

  test(
    'original exact history cleanup requires review, rolls back with policy/receipt on real SQL failure and preserves active work',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(f.dispose);
      final o = f.runtime.service.owner;
      await f.runtime.run(() => o.setAuditRetention(180));
      final item = await f.runtime.run(
        () => o.createInformation('合成清理资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_POLICY_HISTORY'),
        ]),
      );
      final ref = FieldRef(item.id, item.fields.single.id);
      await f.runtime.run(() async {
        final session = f.runtime.service.agent.openSession('合成旧记录');
        final r = f.runtime.service.agent.request(session, '合成读取', [ref]);
        o.approve(r.id, [ref]);
        await f.runtime.service.agent.read(
          f.runtime.service.agent.claim(session, r.id).token,
          ref,
        );
        f.runtime.service.agent.endSession(session);
      });
      now = now.add(const Duration(days: 120));
      final active = await f.runtime.run(() async {
        final session = f.runtime.service.agent.openSession('合成当前任务');
        return f.runtime.service.agent.request(session, '保持待处理', [ref]);
      });
      final p = await read(f);
      expect(p.retentionDays, 180);
      await expectLater(
        save(f, command(p, 'no-cleanup-review', retention: 90)),
        fails('retention_changed'),
      );
      final preview = retentionPreviewFromJson(
        await f.owner.request('POST', '/v1/owner/settings/retention-preview', {
          'wireVersion': 1,
          'generation': p.generation,
          'days': 90,
        }),
      );
      expect(preview.requests, greaterThan(0));
      expect(preview.grants, greaterThan(0));
      expect(preview.operations, greaterThan(0));
      final history = f.repo.accessRecords.map((a) => a.toJson()).toList();
      await sql(
        f,
        "CREATE TRIGGER fail_policy BEFORE INSERT ON desktop_preference_operations BEGIN SELECT RAISE(ABORT,'synthetic policy failure'); END",
      );
      final c = command(
        p,
        'failed-policy',
        retention: 90,
        token: preview.token,
      );
      await expectLater(save(f, c), fails('save_failed'));
      expect((await read(f)).json, p.json);
      expect(f.repo.accessRecords.map((a) => a.toJson()), history);
      await expectLater(
        f.owner.request('GET', query(c)),
        fails('operation_not_found'),
      );
      await sql(f, 'DROP TRIGGER fail_policy');
      await expectLater(save(f, c), fails('not_submitted'));
      final retry = command(
        p,
        'reviewed-policy',
        retention: 90,
        token: preview.token,
      );
      expect((await save(f, retry)).matches(retry), isTrue);
      expect(f.repo.accessRecords, isEmpty);
      expect(f.repo.grantHistory, isEmpty);
      expect(o.requests.any((r) => r.id == active.id), isTrue);
      await f.reopen();
      expect((await read(f)).retentionDays, 90);
      expect(
        (await f.owner.request(
          'GET',
          '/v1/owner/settings/notification-preview',
        ))['requestId'],
        active.id,
      );
    },
  );

  test(
    'portable restore changes policy generation so an old same-version command cannot modify the restored library',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final before = await read(f);
      final c = command(before, 'old-library-policy');
      final key = await f.runtime.run(() => f.repo.backups.enable());
      final archive = '${f.root.path}/empty-policy.aimbackup';
      await f.runtime.run(() async {
        await f.repo.backups.saveRecoveryKeyTo('${f.root.path}/recovery.key');
        await f.runtime.service.owner.exportLibrary(
          () => f.repo.backups.exportTo(archive),
        );
      });
      await f.runtime.run(
        () => f.runtime.service.owner.restoreLibrary(
          () => f.repo.backups.restoreFrom(archive, key),
        ),
      );
      final restored = await read(f);
      expect(restored.generation, isNot(before.generation));
      expect(restored.version, before.version);
      await expectLater(save(f, c), fails('library_changed'));
      await expectLater(
        f.owner.request('GET', query(c)),
        fails('library_changed'),
      );
      expect((await read(f)).json, restored.json);
      expect(
        (await save(
          f,
          command(restored, 'restored-policy'),
        )).policy.requestMinutes,
        60,
      );
    },
  );
}
