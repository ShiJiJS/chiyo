import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/runtime_controller.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

class RuntimePort implements WorkspaceRuntimeSource {
  RuntimePort(this.inner);
  final WorkspaceRuntimeSource inner;
  final writes = <WorkspaceRuntimeChange>[],
      queries = <String>[],
      releases = <String>[];
  bool absent = false, wrong = false, wrongCounts = false, offline = false;
  Future<WorkspaceRuntimeStatus> Function()? readOverride;
  Future<WorkspaceQuitPreview> Function()? previewOverride;
  WorkspaceRuntimeReceipt project(WorkspaceRuntimeReceipt r) {
    final p = r.quitScope;
    return WorkspaceRuntimeReceipt(
      operationId: r.operationId,
      commandDigest: wrong ? 'wrong' : r.commandDigest,
      action: r.action,
      expectedVersion: r.expectedVersion,
      version: r.version,
      phase: r.phase,
      windowHidden: r.windowHidden,
      checked: r.checked,
      released: r.released,
      retained: r.retained,
      quitScope: p == null
          ? null
          : WorkspaceQuitPreview(
              token: p.token,
              version: p.version,
              sessions: wrongCounts ? p.sessions + 1 : p.sessions,
              grants: p.grants,
              pendingRequests: p.pendingRequests,
              materials: p.materials,
              copies: p.copies,
              unconfirmedProcesses: p.unconfirmedProcesses,
            ),
    );
  }

  @override
  Future<WorkspaceRuntimeStatus> status() =>
      readOverride?.call() ?? inner.status();
  @override
  Future<WorkspaceQuitPreview> previewQuit() =>
      previewOverride?.call() ?? inner.previewQuit();
  @override
  Future<void> releaseQuit(String token) {
    releases.add(token);
    return inner.releaseQuit(token);
  }

  @override
  Future<WorkspaceRuntimeReceipt> change(WorkspaceRuntimeChange c) async {
    writes.add(c);
    if (absent) throw const WorkspaceFailure('unknown_outcome', '未知');
    return project(await inner.change(c));
  }

  @override
  Future<WorkspaceRuntimeReceipt?> receipt(String id) async {
    queries.add(id);
    if (offline) throw const WorkspaceFailure('offline', '查询失败');
    final r = await inner.receipt(id);
    return r == null ? null : project(r);
  }
}

void main() {
  const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey'),
      resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume');
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  late SampleWorkspaceSource s;
  setUp(
    () => s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes()),
  );
  tearDown(() => s.dispose());
  Future<WorkspaceRuntimeReceipt> write(
    WorkspaceRuntimeAction action, {
    String? token,
    String? id,
  }) async => s.runtime.change(
    WorkspaceRuntimeChange(
      operationId: id ?? workspaceOperationId(),
      action: action,
      expectedVersion: (await s.runtime.status()).version,
      quitToken: token,
    ),
  );
  Future<WorkspaceCredentialReceipt> request(String operation) async {
    final d = await s.credentials.read(ssh),
        session = (await s.credentials.sessions()).first,
        receiver = (await s.credentials.receivers(ssh)).first;
    return s.credentials.requestUse(
      WorkspaceCredentialUseDraft(
        operationId: operation,
        ref: ssh,
        expectedRecordVersion: d.recordVersion,
        expectedMaterialVersion: d.materialVersion,
        useGeneration: d.useGeneration,
        purpose: '运行状态验收',
        receiverId: receiver.id,
        sessionId: session.id,
      ),
    );
  }

  test(
    'maintenance derives canonical process and copy facts; blocked and active registrations remain while confirmed ended material can release',
    () async {
      await s.prepareRuntimeMaintenance();
      final before = await s.runtime.status(),
          grant = await s.approvals.read('server'),
          file = await s.readDetail(resume);
      expect(before.materials.length, 3);
      expect(
        before.copies.where((e) => e.state == WorkspaceCopyState.active).length,
        1,
      );
      expect(
        before.copies
            .where((e) => e.state == WorkspaceCopyState.pending)
            .length,
        1,
      );
      final material = await write(WorkspaceRuntimeAction.checkMaterials);
      expect(material.checked, 1);
      expect(material.released, 0);
      expect(material.retained, 2);
      final copies = await write(WorkspaceRuntimeAction.checkAttachments);
      expect(copies.checked, 1);
      expect(copies.released, 0);
      expect(copies.retained, 2);
      s.runtime.allowCleanup();
      final released = await write(WorkspaceRuntimeAction.checkMaterials);
      expect(released.released, 1);
      expect(released.retained, 1);
      final after = await s.runtime.status();
      final unknown = after.materials.singleWhere(
        (e) => e.state == WorkspaceExecutionState.unknown,
      );
      expect(unknown.processEnded, false);
      expect(unknown.cleanup, WorkspaceExecutionCleanup.needsCheck);
      expect(
        (await s.approvals.execution(
          unknown.requestId,
          unknown.operationId,
        )).observationDigest,
        unknown.observationDigest,
      );
      final releasedCopies = await write(
        WorkspaceRuntimeAction.checkAttachments,
      );
      expect(releasedCopies.released, 1);
      expect(releasedCopies.retained, 1);
      expect((await s.readDetail(resume)).values, file.values);
      expect(
        (await s.approvals.read('server')).credentialExpiresAt,
        grant.credentialExpiresAt,
      );
      s.advanceApprovalClock(const Duration(minutes: 121));
      final expired = await write(WorkspaceRuntimeAction.checkAttachments);
      expect(expired.released, 1);
      expect(
        (await s.runtime.status()).copies.every(
          (e) => e.state == WorkspaceCopyState.released,
        ),
        true,
      );
    },
  );
  test(
    'maintenance failure retains source and original operation replay never repeats cleanup',
    () async {
      await s.prepareRuntimeMaintenance();
      final before = await s.runtime.status();
      s.runtime.nextMaintenanceFailure = const WorkspaceFailure(
        'unavailable',
        '核查失败',
      );
      await expectLater(
        write(WorkspaceRuntimeAction.checkMaterials, id: 'failed'),
        fails('unavailable'),
      );
      expect((await s.runtime.status()).version, before.version);
      expect(await s.runtime.receipt('failed'), isNull);
      s.runtime.allowCleanup();
      final c = WorkspaceRuntimeChange(
            operationId: 'check',
            action: WorkspaceRuntimeAction.checkMaterials,
            expectedVersion: before.version,
          ),
          r = await s.runtime.change(c);
      final version = (await s.runtime.status()).version;
      expect(await s.runtime.change(c), same(r));
      expect((await s.runtime.status()).version, version);
      await expectLater(
        s.runtime.change(
          WorkspaceRuntimeChange(
            operationId: 'check',
            action: WorkspaceRuntimeAction.checkAttachments,
            expectedVersion: before.version,
          ),
        ),
        fails('operation_conflict'),
      );
    },
  );
  test(
    'menu-bar failure keeps visible window; hide/show does not change grant duration or preferences',
    () async {
      await s.prepareRuntimeMaintenance();
      final grant = await s.approvals.read('server');
      s.runtime.setAvailability(menuBar: false);
      await expectLater(
        write(WorkspaceRuntimeAction.hideWindow),
        fails('menu_bar_unavailable'),
      );
      expect((await s.runtime.status()).windowHidden, false);
      s.runtime.setAvailability(menuBar: true);
      await write(WorkspaceRuntimeAction.hideWindow);
      expect((await s.runtime.status()).windowHidden, true);
      s.runtime.setAvailability(menuBar: false);
      expect((await s.runtime.status()).windowHidden, false);
      s.runtime.setAvailability(menuBar: true);
      await write(WorkspaceRuntimeAction.hideWindow);
      await write(WorkspaceRuntimeAction.showWindow);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.approved,
      );
      expect(
        (await s.approvals.read('server')).credentialExpiresAt,
        grant.credentialExpiresAt,
      );
      expect((await s.settings.read()).background, true);
    },
  );
  test(
    'background preference writes through existing settings, preserves failed draft and never saves another section silently',
    () async {
      final m = WorkspaceSettingsController(
        s.settings,
        const Stream.empty(),
        onTheme: (_) {},
      );
      addTearDown(m.dispose);
      await m.load();
      m.stage(m.draft!.copyWith(requestMinutes: 60));
      await m.setBackground(false);
      expect((await s.settings.read()).background, true);
      m.discard();
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '保存失败');
      await m.setBackground(false);
      expect(m.draft!.background, false);
      expect(m.value!.background, true);
      await m.save();
      expect((await s.settings.read()).background, false);
      await expectLater(
        write(WorkspaceRuntimeAction.hideWindow),
        fails('quit_required'),
      );
    },
  );
  test(
    'quit preview is read-only and cancelled or stale scope never ends authorization',
    () async {
      await s.prepareRuntimeMaintenance();
      final p = await s.runtime.previewQuit();
      expect(p.grants, 2);
      expect(p.pendingRequests, 3);
      expect(p.unconfirmedProcesses, 1);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.approved,
      );
      await s.runtime.releaseQuit(p.token);
      await expectLater(
        write(WorkspaceRuntimeAction.quit, token: p.token),
        fails('quit_changed'),
      );
      await s.approvals.change(decision(await s.approvals.read('token')));
      s.demonstrateApprovalExecutions('token');
      final fresh = await s.runtime.previewQuit();
      expect(
        fresh.unconfirmedProcesses,
        2,
      ); // Includes environment-based use, not just file material.
      expect((await s.runtime.status()).materials.length, 3);
      await request('new-pending');
      await expectLater(
        write(WorkspaceRuntimeAction.quit, token: fresh.token),
        fails('quit_changed'),
      );
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.approved,
      );
    },
  );
  test(
    'definite failure before quit preserves library and active grants; save failure ends capabilities but retains data for retry',
    () async {
      await s.prepareRuntimeMaintenance();
      final data = await s.readDetail(resume),
          p = await s.runtime.previewQuit();
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '保存失败');
      await expectLater(
        write(WorkspaceRuntimeAction.quit, token: p.token),
        fails('disk_full'),
      );
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.approved,
      );
      s.runtime.nextQuitPhase = WorkspaceRuntimePhase.saveFailed;
      final failed = await write(WorkspaceRuntimeAction.quit, token: p.token);
      expect(failed.phase, WorkspaceRuntimePhase.saveFailed);
      expect((await s.runtime.status()).serviceAvailable, false);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.sessionEnded,
      );
      expect((await s.readDetail(resume)).values, data.values);
      await expectLater(
        request('while-stopping'),
        fails('service_unavailable'),
      );
      final retry = await s.runtime.previewQuit();
      expect(retry.grants, 0);
      expect(retry.pendingRequests, 0);
      await write(WorkspaceRuntimeAction.quit, token: retry.token);
      expect((await s.runtime.status()).phase, WorkspaceRuntimePhase.stopped);
    },
  );
  test(
    'termination failure retries only termination; stopped replay after preview resume cannot re-end a new session',
    () async {
      await s.prepareRuntimeMaintenance();
      final p = await s.runtime.previewQuit();
      s.runtime.nextQuitPhase = WorkspaceRuntimePhase.terminationFailed;
      final c = WorkspaceRuntimeChange(
            operationId: 'quit',
            action: WorkspaceRuntimeAction.quit,
            expectedVersion: p.version,
            quitToken: p.token,
          ),
          r = await s.runtime.change(c);
      expect(r.phase, WorkspaceRuntimePhase.terminationFailed);
      s.runtime.nextQuitPhase = WorkspaceRuntimePhase.terminationFailed;
      await write(WorkspaceRuntimeAction.finishExit);
      expect(
        (await s.runtime.status()).phase,
        WorkspaceRuntimePhase.terminationFailed,
      );
      await write(WorkspaceRuntimeAction.finishExit);
      expect((await s.runtime.status()).phase, WorkspaceRuntimePhase.stopped);
      s.runtime.resumePreview();
      final fresh = await request('after-resume'),
          review = await s.approvals.read('credential:${fresh.requestId}');
      await s.approvals.change(decision(review));
      expect(await s.runtime.change(c), same(r));
      expect((await s.runtime.status()).phase, WorkspaceRuntimePhase.running);
      expect(
        (await s.approvals.read(review.request.id)).request.state,
        WorkspaceApprovalState.approved,
      );
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.sessionEnded,
      );
    },
  );
  test(
    'unavailable service disables new requests and maintenance without hiding a window or deleting information',
    () async {
      await s.prepareRuntimeMaintenance();
      final d = await s.readDetail(resume);
      s.runtime.setAvailability(service: false);
      await expectLater(
        write(WorkspaceRuntimeAction.checkAttachments),
        fails('service_unavailable'),
      );
      await expectLater(request('offline'), fails('service_unavailable'));
      expect((await s.readDetail(resume)).values, d.values);
      expect((await s.runtime.status()).copies.length, 2);
    },
  );
  test(
    'pending managed copies protect their original request from audit retention until release',
    () async {
      await s.prepareRuntimeMaintenance();
      s.advanceApprovalClock(const Duration(days: 500));
      final prefs = await s.settings.read(),
          p = await s.settings.previewRetention(30);
      await s.settings.change(
        WorkspaceSettingsChange(
          operationId: 'retention',
          expectedVersion: prefs.version,
          desired: prefs.copyWith(retentionDays: 30),
          retentionToken: p.token,
        ),
      );
      expect((await s.approvals.read('resume')).request.id, 'resume');
      expect((await s.runtime.status()).copies.length, 2);
    },
  );
  test(
    'backup restore does not import runtime copy registrations or material ownership',
    () async {
      await s.prepareRuntimeMaintenance();
      Future<WorkspaceBackupReceipt> backup(
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
      await backup(WorkspaceBackupAction.enableKey);
      final key = (await backup(
        WorkspaceBackupAction.saveKey,
        selection: (await s.backups.choices(
          WorkspaceBackupPick.keyOutput,
        )).first,
      )).resource!;
      final archive = (await backup(
        WorkspaceBackupAction.export,
        selection: (await s.backups.choices(
          WorkspaceBackupPick.archiveOutput,
        )).first,
      )).resource!;
      await s.prepareBackupRecipient();
      final p = await s.backups.inspect(archive, key);
      await backup(
        WorkspaceBackupAction.restore,
        selection: archive,
        token: p.token,
      );
      final restored = await s.runtime.status();
      expect(restored.materials, isEmpty);
      expect(restored.copies, isEmpty);
      expect(
        (await s.approvals.read(
          'server',
        )).executions.every((e) => e.fromBackup),
        true,
      );
    },
  );
  test(
    'unknown maintenance outcome freezes all commands and reconciles only original receipt despite wrong/failed lookups',
    () async {
      await s.prepareRuntimeMaintenance();
      final port = RuntimePort(s.runtime),
          m = WorkspaceRuntimeController(port, const Stream.empty());
      addTearDown(m.dispose);
      await m.load();
      s.runtime.loseNextReply = true;
      await m.write(WorkspaceRuntimeAction.checkMaterials);
      expect(m.uncertain, true);
      expect(await m.closeQuit(), false);
      final id = port.writes.single.operationId;
      await m.write(WorkspaceRuntimeAction.checkAttachments);
      expect(port.writes.length, 1);
      port.offline = true;
      await m.reconcile();
      expect(m.uncertain, true);
      port.offline = false;
      port.wrong = true;
      await m.reconcile();
      expect(m.uncertain, true);
      port.wrong = false;
      await m.reconcile();
      expect(m.uncertain, false);
      expect(port.queries, everyElement(id));
      expect(port.writes.length, 1);
    },
  );
  test(
    'quit receipt counts must match original confirmation; lookup never substitutes a different scope or repeats quit',
    () async {
      await s.prepareRuntimeMaintenance();
      final port = RuntimePort(s.runtime),
          m = WorkspaceRuntimeController(port, const Stream.empty());
      addTearDown(m.dispose);
      await m.load();
      await m.prepareQuit();
      port.wrongCounts = true;
      await m.write(WorkspaceRuntimeAction.quit);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.uncertain, true);
      port.wrongCounts = false;
      await m.reconcile();
      expect(m.value!.phase, WorkspaceRuntimePhase.stopped);
      expect(m.shutdownGate, true);
      expect(port.writes.length, 1);
    },
  );
  test(
    'confirmed non-submission permits explicit retry and cancelled pending quit preview releases its late token',
    () async {
      final port = RuntimePort(s.runtime)..absent = true,
          m = WorkspaceRuntimeController(port, const Stream.empty());
      addTearDown(m.dispose);
      await m.load();
      await m.write(WorkspaceRuntimeAction.checkMaterials);
      await m.reconcile();
      expect(m.failure!.code, 'not_submitted');
      expect(port.writes.length, 1);
      port.absent = false;
      await m.write(WorkspaceRuntimeAction.checkMaterials);
      expect(port.writes.length, 2);
      expect(
        port.writes.first.operationId,
        isNot(port.writes.last.operationId),
      );
      final c = Completer<WorkspaceQuitPreview>();
      port.previewOverride = () => c.future;
      final preparing = m.prepareQuit();
      expect(m.preparing, true);
      expect(await m.closeQuit(), true);
      c.complete(await s.runtime.previewQuit());
      await preparing;
      expect(m.quitPreview, isNull);
      expect(port.releases, isNotEmpty);
      expect(m.preparing, false);
    },
  );
  test(
    'out-of-order status replies cannot restore an obsolete stopped state',
    () async {
      final port = RuntimePort(s.runtime),
          m = WorkspaceRuntimeController(port, const Stream.empty());
      addTearDown(m.dispose);
      final reads = <Completer<WorkspaceRuntimeStatus>>[];
      port.readOverride = () {
        final c = Completer<WorkspaceRuntimeStatus>();
        reads.add(c);
        return c.future;
      };
      final first = m.load(), last = m.load(), real = await s.runtime.status();
      reads.last.complete(real);
      await last;
      reads.first.complete(
        WorkspaceRuntimeStatus(
          version: real.version,
          phase: WorkspaceRuntimePhase.stopped,
          serviceAvailable: false,
          menuBarAvailable: false,
          windowHidden: false,
          materials: [],
          copies: [],
        ),
      );
      await first;
      expect(m.value!.phase, WorkspaceRuntimePhase.running);
      expect(m.shutdownGate, false);
    },
  );
}
