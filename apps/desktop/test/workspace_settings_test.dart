import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _SettingsPort implements WorkspaceSettingsSource {
  _SettingsPort(this.inner);
  final WorkspaceSettingsSource inner;
  final writes = <WorkspaceSettingsChange>[], lookups = <String>[];
  bool absent = false, wrong = false, offline = false;
  Future<WorkspacePreferences> Function()? readOverride;
  WorkspaceSettingsReceipt _project(WorkspaceSettingsReceipt r) => wrong
      ? WorkspaceSettingsReceipt(
          operationId: r.operationId,
          expectedVersion: r.expectedVersion,
          commandDigest: 'wrong-command',
          preferences: r.preferences,
        )
      : r;
  @override
  Future<WorkspacePreferences> read() => readOverride?.call() ?? inner.read();
  @override
  Future<WorkspaceSettingsReceipt> change(WorkspaceSettingsChange c) async {
    writes.add(c);
    if (absent) throw const WorkspaceFailure('unknown_outcome', '结果未知');
    return _project(await inner.change(c));
  }

  @override
  Future<WorkspaceSettingsReceipt?> receipt(String id) async {
    lookups.add(id);
    if (offline) throw const WorkspaceFailure('offline', '查询失败');
    final r = await inner.receipt(id);
    return r == null ? null : _project(r);
  }

  @override
  Future<WorkspaceNotificationPreview> notificationPreview() =>
      inner.notificationPreview();
}

void main() {
  late SampleWorkspaceSource s;
  late _SettingsPort port;
  late WorkspaceSettingsController m;
  final themes = <WorkspaceTheme>[];
  setUp(() {
    s = SampleWorkspaceSource();
    port = _SettingsPort(s.settings);
    themes.clear();
    m = WorkspaceSettingsController(
      port,
      const Stream.empty(),
      onTheme: themes.add,
    );
  });
  tearDown(() {
    m.dispose();
    s.dispose();
  });

  test(
    'session preferences read back across controller recreation; saved theme and notifications share one source',
    () async {
      await m.load();
      expect(m.value!.theme, WorkspaceTheme.light);
      await m.setTheme(WorkspaceTheme.dark);
      await m.setNotifications(false);
      final saved = await s.settings.read();
      expect(saved.version, 3);
      expect(saved.theme, WorkspaceTheme.dark);
      expect(saved.notifications, false);
      expect(saved.requestMinutes, 30);
      expect(saved.retentionDays, 180);
      expect(saved.background, true);
      final another = WorkspaceSettingsController(
        s.settings,
        const Stream.empty(),
        onTheme: themes.add,
      );
      addTearDown(another.dispose);
      await another.load();
      expect(another.value, same(saved));
      expect(themes.last, WorkspaceTheme.dark);
      await s.replaceFixture(sampleWorkspaceJson);
      expect((await s.settings.read()).theme, WorkspaceTheme.dark);
    },
  );
  test(
    'definite failure retains the desired selection without applying its theme; explicit retry saves once',
    () async {
      await m.load();
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '无法保存');
      await m.setTheme(WorkspaceTheme.dark);
      expect(m.draft!.theme, WorkspaceTheme.dark);
      expect(m.value!.theme, WorkspaceTheme.light);
      expect(themes.last, WorkspaceTheme.light);
      expect(m.writeFailure!.code, 'disk_full');
      expect(m.canSave, true);
      await m.save();
      expect((await s.settings.read()).version, 2);
      expect(m.dirty, false);
      expect(themes.last, WorkspaceTheme.dark);
      expect(port.writes, hasLength(2));
      expect(port.writes[0].operationId, isNot(port.writes[1].operationId));
    },
  );
  test(
    'external settings conflict preserves the original draft and cannot silently rebase; explicit adoption uses current values',
    () async {
      await m.load();
      final old = m.value!;
      m.stage(old.copyWith(theme: WorkspaceTheme.dark));
      await s.settings.change(
        WorkspaceSettingsChange(
          operationId: 'other-owner',
          expectedVersion: old.version,
          desired: old.copyWith(notifications: false),
        ),
      );
      await m.save();
      expect(m.writeFailure!.code, 'conflict');
      expect(m.draft!.version, 1);
      await m.load();
      expect(m.value!.notifications, false);
      expect(m.draft!.theme, WorkspaceTheme.dark);
      expect(m.canSave, false);
      expect(m.conflicted, true);
      m.discard();
      expect(m.draft!.version, 2);
      expect(m.draft!.notifications, false);
      expect(m.dirty, false);
      await m.setTheme(WorkspaceTheme.dark);
      expect((await s.settings.read()).notifications, false);
    },
  );
  test(
    'lost settings reply freezes section changes and queries only the original command; wrong or failed receipts never replay it',
    () async {
      await m.load();
      s.settings.loseNextReply = true;
      await m.setTheme(WorkspaceTheme.dark);
      expect(m.frozen, true);
      m.select(WorkspaceSettingsSection.notifications);
      expect(m.section, WorkspaceSettingsSection.appearance);
      expect(m.value!.version, 1);
      port.offline = true;
      await m.reconcile();
      expect(m.uncertain, true);
      port.offline = false;
      port.wrong = true;
      await m.reconcile();
      expect(m.uncertain, true);
      port.wrong = false;
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.value!.version, 2);
      expect(m.draft!.theme, WorkspaceTheme.dark);
      expect(port.writes, hasLength(1));
      expect(port.lookups.toSet(), {port.writes.single.operationId});
    },
  );
  test(
    'confirmed absence keeps choices and requires an explicit new save operation',
    () async {
      await m.load();
      port.absent = true;
      await m.setNotifications(false);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.writeFailure!.code, 'not_submitted');
      expect(m.draft!.notifications, false);
      expect(port.writes, hasLength(1));
      port.absent = false;
      await m.save();
      expect(port.writes, hasLength(2));
      expect(port.writes[0].operationId, isNot(port.writes[1].operationId));
      expect((await s.settings.read()).version, 2);
    },
  );
  test(
    'source operation IDs bind complete settings values; replay is idempotent and conflicting reuse or stale version never writes',
    () async {
      final old = await s.settings.read(),
          c = WorkspaceSettingsChange(
            operationId: 'save-once',
            expectedVersion: 1,
            desired: const WorkspacePreferences(theme: WorkspaceTheme.dark),
          );
      final result = await s.settings.change(c);
      expect(await s.settings.change(c), same(result));
      await expectLater(
        s.settings.change(
          WorkspaceSettingsChange(
            operationId: 'save-once',
            expectedVersion: 1,
            desired: old.copyWith(notifications: false),
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'operation_conflict',
          ),
        ),
      );
      await expectLater(
        s.settings.change(
          WorkspaceSettingsChange(
            operationId: 'stale',
            expectedVersion: 1,
            desired: old.copyWith(notifications: false),
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      expect((await s.settings.read()).version, 2);
    },
  );
  test(
    'late reads do not replace newer observations and read failure retains draft while disabling save',
    () async {
      final replies = <Completer<WorkspacePreferences>>[];
      port.readOverride = () {
        final c = Completer<WorkspacePreferences>();
        replies.add(c);
        return c.future;
      };
      final a = m.load(), b = m.load();
      replies[1].complete(
        const WorkspacePreferences(version: 2, theme: WorkspaceTheme.dark),
      );
      await b;
      replies[0].complete(const WorkspacePreferences());
      await a;
      expect(m.value!.version, 2);
      expect(themes, [WorkspaceTheme.dark]);
      m.stage(m.draft!.copyWith(notifications: false));
      final failed = m.load();
      replies.last.completeError(const WorkspaceFailure('offline', '读取失败'));
      await failed;
      expect(m.draft!.notifications, false);
      expect(m.canSave, false);
      expect(m.readFailure!.code, 'offline');
    },
  );
  test(
    'notification preview is metadata for the exact pending request and never approves it or saves settings',
    () async {
      final p = await s.settings.notificationPreview();
      expect(p.requestId, isNotNull);
      expect(p.title, '有新的访问请求');
      expect(p.description, isNot(contains('SSH_KEY_FILE')));
      expect(
        (await s.approvals.read(p.requestId!)).request.state,
        WorkspaceApprovalState.pending,
      );
      expect((await s.settings.read()).version, 1);
      expect((await s.loadSummary()).pending, 5);
      s.setScenario(SampleWorkspaceScenario.empty);
      expect((await s.settings.notificationPreview()).requestId, isNull);
    },
  );
  test(
    'reset during settings write preparation cancels it without changing session preferences',
    () async {
      final old = await s.settings.read();
      s.setScenario(SampleWorkspaceScenario.waiting);
      final pending = expectLater(
        s.settings.change(
          WorkspaceSettingsChange(
            operationId: 'late',
            expectedVersion: old.version,
            desired: old.copyWith(theme: WorkspaceTheme.dark),
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await s.replaceFixture(sampleWorkspaceJson);
      await pending;
      expect((await s.settings.read()).version, 1);
      expect((await s.settings.read()).theme, WorkspaceTheme.light);
    },
  );
}
