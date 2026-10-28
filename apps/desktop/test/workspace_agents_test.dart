import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/agents_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

class AgentPort implements WorkspaceAgentsSource {
  AgentPort(this.inner);
  final WorkspaceAgentsSource inner;
  Future<WorkspaceAgentOverview> Function()? readOverride, diagnosticOverride;
  Future<WorkspaceAgentSessionDetail> Function()? sessionOverride;
  int diagnostics = 0;
  @override
  Future<WorkspaceAgentOverview> read() => readOverride?.call() ?? inner.read();
  @override
  Future<WorkspaceAgentOverview> diagnose(int version) {
    diagnostics++;
    return diagnosticOverride?.call() ?? inner.diagnose(version);
  }

  @override
  Future<WorkspaceAgentSessionDetail> currentSession(int version) =>
      sessionOverride?.call() ?? inner.currentSession(version);
}

void main() {
  late SampleWorkspaceSource s;
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  setUp(
    () => s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes()),
  );
  tearDown(() => s.dispose());
  WorkspaceAgentsController controller(
    WorkspaceAgentsSource p, {
    bool changes = false,
  }) {
    final m = WorkspaceAgentsController(
      p,
      changes ? s.changes : const Stream.empty(),
    );
    addTearDown(m.dispose);
    return m;
  }

  Future<WorkspaceRuntimeReceipt> runtime(
    WorkspaceRuntimeAction action, {
    String? token,
  }) async => s.runtime.change(
    WorkspaceRuntimeChange(
      operationId: workspaceOperationId(),
      action: action,
      expectedVersion: (await s.runtime.status()).version,
      quitToken: token,
    ),
  );
  test(
    'read-only overview and details agree without creating requests or grants',
    () async {
      final before = await s.approvals.query(const WorkspaceApprovalQuery()),
          prefs = await s.settings.read();
      final v = await s.agents.read(),
          report = await s.agents.diagnose(v.version),
          detail = await s.agents.currentSession(v.version);
      expect(v.valid, true);
      expect(v.connection, WorkspaceAgentConnection.ready);
      expect(v.session.pendingRequests, 5);
      expect(v.session.activeGrants, 0);
      expect(report.fingerprint, v.fingerprint);
      expect(detail.matches(v), true);
      expect(
        detail.requests.map((r) => r.id).toSet(),
        before.items.map((r) => r.id).toSet(),
      );
      expect(
        (await s.approvals.query(const WorkspaceApprovalQuery())).total,
        before.total,
      );
      expect((await s.settings.read()).values, prefs.values);
    },
  );
  test(
    'missing tools, untrusted hooks and changed definitions block connected state',
    () async {
      for (final scenario in [
        SampleAgentScenario.missingCli,
        SampleAgentScenario.missingSkill,
        SampleAgentScenario.missingHooks,
        SampleAgentScenario.untrustedHooks,
        SampleAgentScenario.changedCommand,
      ]) {
        await s.agents.setScenario(scenario);
        final v = await s.agents.read();
        expect(
          v.connection,
          scenario == SampleAgentScenario.missingCli ||
                  scenario == SampleAgentScenario.missingSkill
              ? WorkspaceAgentConnection.toolsMissing
              : WorkspaceAgentConnection.hooksUntrusted,
        );
        if (scenario == SampleAgentScenario.changedCommand) {
          expect(
            v.hooks.every(
              (h) => h.observedState == WorkspaceAgentCheck.changed,
            ),
            true,
          );
          expect(
            v.hooks.every((h) => h.trustedDefinitionId != h.definitionId),
            true,
          );
        }
      }
    },
  );
  test(
    'all three events need full commands, positive timeouts and exact definition trust',
    () async {
      WorkspaceAgentHook hook({
        String command = 'same-name',
        String id = 'new',
        String? trust = 'old',
        int timeout = 3,
      }) => WorkspaceAgentHook(
        event: 'SessionEnd',
        state: WorkspaceAgentCheck.ready,
        command: command,
        definitionId: id,
        trustedDefinitionId: trust,
        timeoutSeconds: timeout,
      );
      expect(hook().observedState, WorkspaceAgentCheck.changed);
      expect(hook(trust: null).observedState, WorkspaceAgentCheck.untrusted);
      expect(hook(command: '').observedState, WorkspaceAgentCheck.unavailable);
      expect(hook(timeout: 0).verified, false);
      final v = await s.agents.read();
      WorkspaceAgentOverview project(List<WorkspaceAgentHook> hooks) =>
          WorkspaceAgentOverview(
            version: v.version,
            observedAt: v.observedAt,
            serviceAvailable: true,
            cli: v.cli,
            skill: v.skill,
            hooks: hooks,
            session: v.session,
          );
      expect(project(v.hooks.skip(1).toList()).hooksReady, false);
      expect(project([...v.hooks, v.hooks.first]).valid, false);
      expect(project([...v.hooks, v.hooks.first]).hooksReady, false);
    },
  );
  test(
    'missing or mismatched association never guesses public session requests',
    () async {
      for (final scenario in [
        SampleAgentScenario.noAssociation,
        SampleAgentScenario.bindingMismatch,
      ]) {
        await s.agents.setScenario(scenario);
        final v = await s.agents.read(),
            d = await s.agents.currentSession((await s.agents.read()).version);
        expect(v.session.id, isNull);
        expect(v.session.totalRequests, 0);
        expect(d.requests, isEmpty);
        expect(d.matches(v), true);
      }
      expect(
        (await s.approvals.query(const WorkspaceApprovalQuery())).total,
        5,
      );
    },
  );
  test(
    'approval and root end share canonical grants; app resume never reconnects ended chat',
    () async {
      final d = await s.approvals.read('server');
      await s.approvals.change(decision(d));
      expect((await s.agents.read()).session.activeGrants, 1);
      s.endApprovalSession(d.request.sessionId);
      final ended = await s.agents.read();
      expect(ended.session.state, WorkspaceAgentSessionState.ended);
      expect(ended.session.pendingRequests, 0);
      expect(ended.session.activeGrants, 0);
      final quit = await s.runtime.previewQuit();
      await runtime(WorkspaceRuntimeAction.quit, token: quit.token);
      expect(
        (await s.agents.read()).connection,
        WorkspaceAgentConnection.serviceUnavailable,
      );
      s.runtime.resumePreview();
      final resumed = await s.agents.read();
      expect(resumed.session.id, ended.session.id);
      expect(resumed.session.state, WorkspaceAgentSessionState.ended);
      expect(resumed.session.activeGrants, 0);
      await s.agents.setScenario(SampleAgentScenario.freshSession);
      final fresh = await s.agents.read();
      expect(fresh.session.id, isNot(ended.session.id));
      expect(fresh.session.totalRequests, 0);
      expect(fresh.session.activeGrants, 0);
    },
  );
  test(
    'fresh chat shows only explicitly requested new use and its subsequent approval',
    () async {
      await s.agents.setScenario(SampleAgentScenario.freshSession);
      const ref = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
      final d = await s.credentials.read(ref),
          session = (await s.credentials.sessions()).first,
          receiver = (await s.credentials.receivers(ref)).first;
      final created = await s.credentials.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: workspaceOperationId(),
          ref: ref,
          expectedRecordVersion: d.recordVersion,
          expectedMaterialVersion: d.materialVersion,
          useGeneration: d.useGeneration,
          purpose: '新聊天明确申请',
          receiverId: receiver.id,
          sessionId: session.id,
        ),
      );
      final v = await s.agents.read(),
          detail = await s.agents.currentSession(
            (await s.agents.read()).version,
          );
      expect(v.session.totalRequests, 1);
      expect(v.session.activeGrants, 0);
      expect(detail.requests.single.id, 'credential:${created.requestId}');
      await s.approvals.change(
        decision(await s.approvals.read('credential:${created.requestId}')),
      );
      expect((await s.agents.read()).session.activeGrants, 1);
    },
  );
  test(
    'restore invalidates association while preserving untrusted changed local definitions',
    () async {
      Future<WorkspaceBackupReceipt> write(
        WorkspaceBackupAction a, {
        WorkspaceBackupResource? selection,
        String? token,
      }) async => s.backups.change(
        WorkspaceBackupChange(
          operationId: workspaceOperationId(),
          action: a,
          expectedVersion: (await s.backups.status()).version,
          selection: selection,
          previewToken: token,
        ),
      );
      await s.prepareBackupExportFixture();
      await write(WorkspaceBackupAction.enableKey);
      final key = (await write(
        WorkspaceBackupAction.saveKey,
        selection: (await s.backups.choices(
          WorkspaceBackupPick.keyOutput,
        )).first,
      )).resource!;
      final archive = (await write(
        WorkspaceBackupAction.export,
        selection: (await s.backups.choices(
          WorkspaceBackupPick.archiveOutput,
        )).first,
      )).resource!;
      await s.prepareBackupRecipient();
      await s.agents.setScenario(SampleAgentScenario.changedCommand);
      final local = await s.agents.read(),
          preview = await s.backups.inspect(archive, key);
      await write(
        WorkspaceBackupAction.restore,
        selection: archive,
        token: preview.token,
      );
      final after = await s.agents.read();
      expect(after.session.state, WorkspaceAgentSessionState.missing);
      expect(after.session.totalRequests, 0);
      expect(after.hooks.map((h) => h.json), local.hooks.map((h) => h.json));
      expect(after.hooksReady, false);
    },
  );
  test(
    'obsolete versions and one-shot read faults preserve canonical request state',
    () async {
      final v = await s.agents.read();
      await s.agents.setScenario(SampleAgentScenario.bindingMismatch);
      await expectLater(
        s.agents.diagnose(v.version),
        fails('observation_changed'),
      );
      await expectLater(
        s.agents.currentSession(v.version),
        fails('observation_changed'),
      );
      s.agents.nextDiagnosticFailure = const WorkspaceFailure(
        'offline',
        '暂时离线',
      );
      final current = await s.agents.read();
      await expectLater(s.agents.diagnose(current.version), fails('offline'));
      expect(
        (await s.approvals.query(const WorkspaceApprovalQuery())).pending,
        5,
      );
    },
  );
  test(
    'chat request summaries agree with confirmed pending and active counts',
    () async {
      final v = await s.agents.read(),
          detail = await s.agents.currentSession(
            (await s.agents.read()).version,
          );
      final altered = WorkspaceAgentSession(
        state: v.session.state,
        id: v.session.id,
        label: v.session.label,
        totalRequests: v.session.totalRequests,
        pendingRequests: 0,
        activeGrants: 0,
      );
      final wrong = WorkspaceAgentOverview(
        version: v.version,
        observedAt: v.observedAt,
        serviceAvailable: v.serviceAvailable,
        cli: v.cli,
        skill: v.skill,
        hooks: v.hooks,
        session: altered,
      );
      expect(
        WorkspaceAgentSessionDetail(
          overviewFingerprint: wrong.fingerprint,
          session: altered,
          requests: detail.requests,
        ).matches(wrong),
        false,
      );
    },
  );
  test('latest overview ignores an old read failure', () async {
    final port = AgentPort(s.agents),
        m = controller(port),
        old = Completer<WorkspaceAgentOverview>();
    port.readOverride = () => old.future;
    final pending = m.load();
    port.readOverride = null;
    await s.agents.setScenario(SampleAgentScenario.noAssociation);
    await m.load();
    old.completeError(const WorkspaceFailure('offline', '旧失败'));
    await pending;
    expect(m.available, true);
    expect(m.value!.connection, WorkspaceAgentConnection.associationMissing);
    expect(m.readFailure, isNull);
  });
  test(
    'same-mode reopen ignores old diagnostic without clearing new busy state',
    () async {
      final port = AgentPort(s.agents), m = controller(port);
      await m.load();
      m.open(WorkspaceAgentView.diagnostics);
      final old = Completer<WorkspaceAgentOverview>(),
          fresh = Completer<WorkspaceAgentOverview>();
      port.diagnosticOverride = () => old.future;
      final first = m.readDetails();
      m.close();
      m.open(WorkspaceAgentView.diagnostics);
      port.diagnosticOverride = () => fresh.future;
      final second = m.readDetails();
      old.complete(await s.agents.read());
      await first;
      expect(m.report, isNull);
      expect(m.detailBusy, true);
      fresh.complete(await s.agents.read());
      await second;
      expect(m.report, isNotNull);
      expect(m.detailBusy, false);
    },
  );
  test(
    'closing during initial read cannot launch late details into reopened mode',
    () async {
      final port = AgentPort(s.agents),
          m = controller(port),
          old = Completer<WorkspaceAgentOverview>();
      port.readOverride = () => old.future;
      m.open(WorkspaceAgentView.diagnostics);
      final pending = m.readDetails();
      m.close();
      m.open(WorkspaceAgentView.diagnostics);
      old.complete(await s.agents.read());
      await pending;
      expect(port.diagnostics, 0);
      expect(m.report, isNull);
      port.readOverride = null;
      await m.readDetails();
      expect(port.diagnostics, 1);
    },
  );
  test(
    'wrong report fingerprint and wrong session binding are rejected',
    () async {
      final port = AgentPort(s.agents), m = controller(port);
      await m.load();
      final old = m.value!;
      await s.agents.setScenario(SampleAgentScenario.noAssociation);
      port.diagnosticOverride = () => s.agents.read();
      m.open(WorkspaceAgentView.diagnostics);
      await m.readDetails();
      expect(m.report, isNull);
      expect(m.detailFailure!.code, 'observation_changed');
      await s.agents.setScenario(SampleAgentScenario.ready);
      await m.load();
      port.sessionOverride = () async => WorkspaceAgentSessionDetail(
        overviewFingerprint: old.fingerprint,
        session: const WorkspaceAgentSession(
          state: WorkspaceAgentSessionState.linked,
          id: 'wrong-session',
          totalRequests: 0,
          pendingRequests: 0,
          activeGrants: 0,
        ),
        requests: [],
      );
      m.open(WorkspaceAgentView.session);
      await m.readDetails();
      expect(m.session, isNull);
      expect(m.detailFailure!.code, 'observation_changed');
    },
  );
  test(
    'unknown read outcome retries and closes freely without write freeze',
    () async {
      final m = controller(s.agents);
      s.agents.nextReadFailure = const WorkspaceFailure(
        'unknown_outcome',
        '无法观察',
      );
      await m.load();
      expect(m.readFailure!.code, 'unavailable');
      expect(m.available, false);
      await m.load();
      m.open(WorkspaceAgentView.session);
      s.agents.nextSessionFailure = const WorkspaceFailure(
        'unknown_outcome',
        '无法观察',
      );
      await m.readDetails();
      expect(m.detailFailure!.code, 'unavailable');
      m.close();
      expect(m.view, isNull);
      await m.load();
      m.open(WorkspaceAgentView.session);
      await m.readDetails();
      expect(m.session!.requests.length, 5);
    },
  );
  test(
    'source change clears old requests and refreshes current association',
    () async {
      final m = controller(s.agents, changes: true);
      await m.load();
      m.open(WorkspaceAgentView.session);
      await m.readDetails();
      expect(m.session!.requests.length, 5);
      await s.agents.setScenario(SampleAgentScenario.bindingMismatch);
      for (
        var i = 0;
        i < 30 &&
            (m.loading ||
                m.session == null ||
                m.session!.session.state !=
                    WorkspaceAgentSessionState.mismatch);
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(m.session!.session.state, WorkspaceAgentSessionState.mismatch);
      expect(m.session!.requests, isEmpty);
      expect(m.available, true);
    },
  );
}
