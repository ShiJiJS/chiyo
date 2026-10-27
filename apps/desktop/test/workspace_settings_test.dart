import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

class _SettingsPort implements WorkspaceSettingsSource {
  _SettingsPort(this.inner);
  final WorkspaceSettingsSource inner;
  final writes = <WorkspaceSettingsChange>[], lookups = <String>[];
  bool absent = false, wrong = false, offline = false;
  Future<WorkspacePreferences> Function()? readOverride;
  Future<WorkspaceRetentionPreview> Function(int)? previewOverride;
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
  @override
  Future<WorkspaceRetentionPreview> previewRetention(int days) =>
      previewOverride?.call(days) ?? inner.previewRetention(days);
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

  Future<WorkspaceCredentialUseRequest> request(String operation) async {
    const ref = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
    final d = await s.credentials.read(ref);
    final receipt = await s.credentials.requestUse(
      WorkspaceCredentialUseDraft(
        operationId: operation,
        ref: ref,
        expectedRecordVersion: d.recordVersion,
        expectedMaterialVersion: d.materialVersion,
        useGeneration: d.useGeneration,
        purpose: '核对合成服务',
        receiverId: (await s.credentials.receivers(ref)).first.id,
        sessionId: (await s.credentials.sessions()).first.id,
      ),
    );
    return (await s.approvals.read(
      'credential:${receipt.requestId}',
    )).credential!;
  }

  test(
    'cancelled preview reading releases navigation and a late old scope cannot replace the next review',
    () async {
      await m.load();
      m.stage(m.draft!.copyWith(retentionDays: 30));
      final replies = <Completer<WorkspaceRetentionPreview>>[];
      port.previewOverride = (days) {
        final c = Completer<WorkspaceRetentionPreview>();
        replies.add(c);
        return c.future;
      };
      final first = m.prepareRetention();
      expect(m.frozen, true);
      m.cancelRetention();
      expect(m.frozen, false);
      final second = m.prepareRetention();
      final p = await s.settings.previewRetention(30);
      replies[1].complete(p);
      await second;
      expect(m.retentionPreview, same(p));
      replies[0].completeError(const WorkspaceFailure('offline', '旧读取失败'));
      await first;
      expect(m.retentionPreview, same(p));
      expect(m.retentionFailure, isNull);
      expect(m.canSave, false);
      m.confirmRetention(p);
      expect(m.canSave, true);
      m.stage(m.draft!.copyWith(retentionDays: 90));
      expect(m.canSave, false);
      m.confirmRetention(p);
      expect(m.canSave, false);
    },
  );

  Future<void> review(int days) async {
    m.stage(m.draft!.copyWith(retentionDays: days));
    await m.prepareRetention();
    m.confirmRetention(m.retentionPreview!);
  }

  test(
    'new request waiting deadlines are captured at submission and never rewrite old requests or grant deadlines',
    () async {
      await m.load();
      final oldSeed = (await s.approvals.read('server')).request;
      final first = await request('first');
      expect(
        first.requestExpiresAt!.difference(first.submittedAt),
        const Duration(minutes: 30),
      );
      final firstDeadline = first.requestExpiresAt;
      m.stage(m.draft!.copyWith(requestMinutes: 5));
      await m.save();
      final second = await request('second');
      expect(
        second.requestExpiresAt!.difference(second.submittedAt),
        const Duration(minutes: 5),
      );
      expect(
        (await s.approvals.read('server')).request.requestExpiresAt,
        oldSeed.requestExpiresAt,
      );
      expect(
        (await s.approvals.read(first.approvalId)).request.requestExpiresAt,
        firstDeadline,
      );
      s.advanceApprovalClock(const Duration(minutes: 6));
      expect(
        (await s.approvals.read(second.approvalId)).request.state,
        WorkspaceApprovalState.expired,
      );
      expect(
        (await s.approvals.read(first.approvalId)).request.state,
        WorkspaceApprovalState.pending,
      );
      final third = await request('third');
      expect(
        third.submittedAt,
        first.submittedAt.add(const Duration(minutes: 6)),
      );
      final d = await s.approvals.read(first.approvalId);
      await s.approvals.change(decision(d));
      final granted = await s.approvals.read(first.approvalId);
      m.stage(m.draft!.copyWith(requestMinutes: 120));
      await m.save();
      expect(
        (await s.approvals.read(first.approvalId)).credentialExpiresAt,
        granted.credentialExpiresAt,
      );
    },
  );

  test(
    'retention preview is read only; missing or cancelled confirmation cannot prune or change preferences',
    () async {
      await m.load();
      final before = await s.grantHistory.query(const WorkspaceGrantQuery());
      s.advanceApprovalClock(const Duration(days: 60));
      m.stage(m.draft!.copyWith(retentionDays: 30));
      await m.save();
      expect(port.writes, isEmpty);
      await expectLater(
        s.settings.change(
          WorkspaceSettingsChange(
            operationId: 'bypass',
            expectedVersion: 1,
            desired: m.draft!,
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'review_required',
          ),
        ),
      );
      await m.prepareRetention();
      expect(m.retentionPreview!.grants, before.total);
      expect(m.retentionPreview!.requests, 5);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        before.total,
      );
      m.cancelRetention();
      await m.save();
      expect(port.writes, isEmpty);
      expect((await s.settings.read()).retentionDays, 180);
    },
  );

  test(
    'confirmed retention prunes exact canonical histories and requests, preserves content and receipts, and cannot resurface pending requests',
    () async {
      await m.load();
      await s.approvals.change(
        decision(
          await s.approvals.read('token'),
          action: WorkspaceApprovalAction.deny,
          selected: [],
        ),
      );
      final created = await request('old-request');
      final contentBefore = await s.loadSummary();
      s.advanceApprovalClock(const Duration(days: 60));
      await review(30);
      final p = m.retentionPreview!;
      expect(p.requests, 6);
      expect(p.grants, greaterThan(0));
      expect(p.operations, greaterThan(0));
      await m.save();
      final command = port.writes.single;
      expect((await s.settings.read()).retentionDays, 30);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        0,
      );
      expect(
        (await s.approvals.query(
          const WorkspaceApprovalQuery(filter: WorkspaceApprovalFilter.all),
        )).total,
        0,
      );
      expect((await s.loadSummary()).records, contentBefore.records);
      expect(
        await s.credentials.history(
          const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey'),
        ),
        isEmpty,
      );
      await expectLater(
        s.approvals.read(created.approvalId),
        throwsA(isA<WorkspaceFailure>()),
      );
      final receipt = await s.settings.receipt(command.operationId);
      expect(await s.settings.change(command), same(receipt));
      expect((await s.settings.read()).version, 2);
    },
  );

  test(
    'history changes after preview reject the entire save and require a fresh confirmation',
    () async {
      await m.load();
      s.advanceApprovalClock(const Duration(days: 60));
      await review(30);
      final before = await s.grantHistory.query(const WorkspaceGrantQuery());
      await request('new-during-review');
      await m.save();
      expect(m.writeFailure!.code, 'retention_changed');
      expect((await s.settings.read()).retentionDays, 180);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        before.total,
      );
      expect(m.retentionPreview, isNull);
      expect(m.canSave, false);
      await m.prepareRetention();
      expect(m.retentionPreview!.preserved, greaterThan(0));
      m.confirmRetention(m.retentionPreview!);
      await m.save();
      expect((await s.loadSummary()).pending, 1);
    },
  );

  test(
    'definite save failure prunes nothing; explicit re-review and lost reply resolve exactly once without replay',
    () async {
      await m.load();
      s.advanceApprovalClock(const Duration(days: 60));
      await review(30);
      final before = await s.grantHistory.query(const WorkspaceGrantQuery());
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '空间不足');
      await m.save();
      expect(m.writeFailure!.code, 'disk_full');
      expect(m.draft!.retentionDays, 30);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        before.total,
      );
      expect((await s.settings.read()).retentionDays, 180);
      await m.prepareRetention();
      m.confirmRetention(m.retentionPreview!);
      s.settings.loseNextReply = true;
      await m.save();
      expect(m.uncertain, true);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        0,
      );
      await m.reconcile();
      expect(m.uncertain, false);
      expect(port.writes, hasLength(2));
      expect((await s.settings.read()).version, 2);
    },
  );

  test(
    'running or unresolved execution histories survive retention even after their grant expires',
    () async {
      await m.load();
      await s.approvals.change(decision(await s.approvals.read('server')));
      s.demonstrateApprovalExecutions('server');
      s.advanceApprovalClock(const Duration(days: 60));
      await review(30);
      expect(m.retentionPreview!.preserved, greaterThan(0));
      await m.save();
      final h = await s.grantHistory.read('request:server');
      expect(h.summary.operationCount, greaterThan(0));
      expect((await s.approvals.read('server')).executions, isNotEmpty);
    },
  );

  test(
    'empty cleanup is explicit and preview reset invalidates its exact token',
    () async {
      await m.load();
      s.setScenario(SampleWorkspaceScenario.empty);
      await review(30);
      expect(m.retentionPreview!.requests, 0);
      expect(m.retentionPreview!.grants, 0);
      await m.save();
      expect((await s.settings.read()).retentionDays, 30);
      m.stage(m.draft!.copyWith(retentionDays: 180));
      await m.save();
      await review(90);
      s.setScenario(SampleWorkspaceScenario.ready);
      await m.save();
      expect(m.writeFailure!.code, 'review_required');
      expect((await s.settings.read()).retentionDays, 180);
    },
  );
  test(
    'a recent process-end observation keeps the old execution until that observation also passes the retention cutoff',
    () async {
      await m.load();
      await s.approvals.change(decision(await s.approvals.read('server')));
      s.demonstrateApprovalExecutions('server');
      s.advanceApprovalClock(const Duration(days: 60));
      s.publishApprovalExecutionObservation('server');
      final executions = (await s.approvals.read('server')).executions;
      expect(
        executions
            .where((e) => e.state == WorkspaceExecutionState.unknown)
            .single
            .observedAt,
        isNotNull,
      );
      await review(30);
      await m.save();
      expect(
        (await s.grantHistory.read('request:server')).summary.operationCount,
        3,
      );
      m.stage(m.draft!.copyWith(retentionDays: 90));
      await m.save();
      s.advanceApprovalClock(const Duration(days: 31));
      await review(30);
      expect(m.retentionPreview!.requests, 1);
      expect(m.retentionPreview!.operations, 3);
      await m.save();
      await expectLater(
        s.grantHistory.read('request:server'),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );
}
