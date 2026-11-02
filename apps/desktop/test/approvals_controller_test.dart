import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Port implements WorkspaceApprovalSource {
  _Port(this.inner);
  final WorkspaceApprovalSource inner;
  Future<WorkspaceApprovalExecution> Function(String, String)?
  executionOverride;
  Future<WorkspaceApprovalDetail> Function(String)? readOverride;
  Future<WorkspaceApprovalResults> Function(WorkspaceApprovalQuery, String?)?
  queryOverride;
  bool loseWithoutCommit = false, wrongDigest = false;
  int writes = 0;
  final commands = <WorkspaceApprovalChange>[];
  @override
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) =>
      executionOverride?.call(requestId, operationId) ??
      inner.execution(requestId, operationId);
  @override
  Future<WorkspaceApprovalDetail> read(String id) =>
      readOverride?.call(id) ?? inner.read(id);
  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery q, {
    String? keepSelection,
  }) =>
      queryOverride?.call(q, keepSelection) ??
      inner.query(q, keepSelection: keepSelection);
  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange c) async {
    writes++;
    commands.add(c);
    if (loseWithoutCommit) {
      throw const WorkspaceFailure('unknown_outcome', '确认中');
    }
    final r = await inner.change(c);
    return wrongDigest ? _wrong(r) : r;
  }

  WorkspaceApprovalReceipt _wrong(WorkspaceApprovalReceipt r) =>
      WorkspaceApprovalReceipt(
        operationId: r.operationId,
        requestId: r.requestId,
        action: r.action,
        reviewToken: r.reviewToken,
        revision: r.revision,
        commandDigest: 'another-command',
      );
  @override
  Future<WorkspaceApprovalReceipt?> receipt(String id) async {
    final r = await inner.receipt(id);
    return wrongDigest && r != null ? _wrong(r) : r;
  }
}

void main() {
  late SampleWorkspaceSource s;
  late _Port port;
  late ApprovalsController m;
  setUp(() {
    s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes());
    port = _Port(s.approvals);
    m = ApprovalsController(port, const Stream.empty());
  });
  tearDown(() {
    m.dispose();
    s.dispose();
  });

  test(
    'automatic selection of another request clears the prior decision feedback',
    () async {
      await m.select('server');
      await m.decide(WorkspaceApprovalAction.approve);
      expect(m.notice, contains('已记录'));
      port.queryOverride = (q, keep) async {
        final result = await port.inner.query(q);
        return WorkspaceApprovalResults(
          items: result.items,
          total: result.total,
          pending: result.pending,
          offset: result.offset,
          selection: 'token',
        );
      };
      await m.load();
      expect(m.detail!.request.id, 'token');
      expect(m.detail!.request.state, WorkspaceApprovalState.pending);
      expect(m.notice, isNull);
      await m.search('');
      expect(m.notice, isNull);
    },
  );
  test(
    'missing explicit request stays missing through refresh until owner selects another',
    () async {
      await m.open('does-not-exist');
      expect(m.selection, 'does-not-exist');
      expect(m.detail, isNull);
      expect(m.readFailure?.code, 'not_found');
      expect(m.canDecide, isFalse);
      expect(m.results!.items, isNotEmpty);
      await m.load();
      expect(m.selection, 'does-not-exist');
      expect(m.readFailure?.code, 'not_found');
      await m.select('server');
      expect(m.detail!.request.id, 'server');
      expect(m.readFailure, isNull);
      expect(port.writes, 0);
    },
  );

  test(
    'late query/read and late failure cannot replace newer selection or leave it busy',
    () async {
      await m.load();
      final query = Completer<WorkspaceApprovalResults>();
      port.queryOverride = (_, _) => query.future;
      final oldLoad = m.load();
      await m.select('token');
      expect(m.detail!.request.id, 'token');
      expect(m.loading, false);
      expect(m.reading, false);
      query.completeError(const WorkspaceFailure('offline', '旧列表读取失败'));
      await oldLoad;
      expect(m.readFailure, isNull);
      expect(m.detail!.request.id, 'token');
      port.queryOverride = null;
      final read = Completer<WorkspaceApprovalDetail>();
      port.readOverride = (id) =>
          id == 'server' ? read.future : port.inner.read(id);
      final oldRead = m.select('server');
      await m.select('resume');
      read.complete(await port.inner.read('server'));
      await oldRead;
      expect(m.detail!.request.id, 'resume');
      expect(m.canDecide, true);
    },
  );

  test(
    'unmatched digest freezes exact intent until matching readback; never replays decision',
    () async {
      await m.load();
      final selected = Set.of(m.draft!.selected);
      port.wrongDigest = true;
      await m.decide(WorkspaceApprovalAction.approve);
      expect(m.uncertain, true);
      await m.select('token');
      await m.search('resume');
      expect(m.selection, 'server');
      expect(m.draft!.selected, selected);
      await m.reconcile();
      expect(m.uncertain, true);
      expect(port.writes, 1);
      port.wrongDigest = false;
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.detail!.approved, selected);
      expect(port.writes, 1);
    },
  );

  test(
    'confirmed absent receipt retains file version and separate deadlines until explicit retry',
    () async {
      await m.open('resume');
      final file = m.detail!.scopes.singleWhere(
        (x) => x.kind == WorkspaceApprovalScopeKind.file,
      );
      m.chooseFile(file.id, 1);
      m.lifetime(60);
      m.lifetime(30, credential: true);
      final selected = Set.of(m.draft!.selected);
      port.loseWithoutCommit = true;
      await m.decide(WorkspaceApprovalAction.approve);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.frozen, false);
      expect(port.writes, 1);
      expect(m.draft!.selected, selected);
      expect(m.draft!.files[file.id], 1);
      expect(m.draft!.fieldMinutes, 60);
      expect(m.draft!.credentialMinutes, 30);
      expect(m.detail!.request.state, WorkspaceApprovalState.pending);
      port.loseWithoutCommit = false;
      await m.decide(WorkspaceApprovalAction.approve);
      expect(port.writes, 2);
      expect(
        port.commands.last.operationId,
        isNot(port.commands.first.operationId),
      );
      expect(m.detail!.fileVersions[file.id], 1);
      expect(
        m.detail!.fieldExpiresAt,
        m.detail!.decidedAt!.add(const Duration(minutes: 60)),
      );
      expect(m.detail!.credentialExpiresAt, isNull);
    },
  );

  test(
    'expiry refresh follows selected terminal request; reset removes it and read failure differs from empty',
    () async {
      await m.load();
      s.advanceApprovalClock(const Duration(minutes: 16));
      await m.load();
      expect(m.selection, 'server');
      expect(m.filter, WorkspaceApprovalFilter.all);
      expect(m.detail!.request.state, WorkspaceApprovalState.expired);
      s.setScenario(SampleWorkspaceScenario.failure);
      await m.load();
      expect(m.readFailure, isNotNull);
      expect(m.detail!.request.state, WorkspaceApprovalState.expired);
      s.setScenario(SampleWorkspaceScenario.empty);
      await m.load();
      expect(m.readFailure, isNull);
      expect(m.results!.total, 0);
      expect(m.selection, isNull);
      expect(m.detail, isNull);
      expect(m.loading, false);
    },
  );
  test(
    'execution query preserves unknown on failure/wrong binding and reads only the original observation without a new write',
    () async {
      await m.load();
      await m.decide(WorkspaceApprovalAction.approve);
      s.demonstrateApprovalExecutions('server');
      await m.load();
      final old = m.detail!.executions.last,
          expiry = m.detail!.credentialExpiresAt;
      port.executionOverride = (_, _) async => m.detail!.executions.first;
      await m.refreshExecution(old.operationId);
      expect(m.executionError(old.operationId), contains('原操作不符'));
      expect(
        m.detail!.executions.last.observationDigest,
        old.observationDigest,
      );
      port.executionOverride = (_, _) async => old.observed(
        revision: old.revision,
        processEnded: true,
        cleanup: WorkspaceExecutionCleanup.complete,
      );
      await m.refreshExecution(old.operationId);
      expect(m.executionError(old.operationId), isNotNull);
      port.executionOverride = null;
      s.nextApprovalExecutionReadFailure = const WorkspaceFailure(
        'offline',
        '查询失败',
      );
      await m.refreshExecution(old.operationId);
      expect(m.executionError(old.operationId), '查询失败');
      s.publishApprovalExecutionObservation('server');
      expect(m.detail!.executions.last.processEnded, false);
      await m.refreshExecution(old.operationId);
      expect(m.executionError(old.operationId), isNull);
      expect(m.detail!.executions.last.processEnded, true);
      expect(m.detail!.executions.last.state, WorkspaceExecutionState.unknown);
      expect(m.detail!.executions.last.exitCode, isNull);
      expect(m.detail!.credentialExpiresAt, expiry);
      expect(m.detail!.executions, hasLength(3));
      expect(port.writes, 1);
    },
  );

  test(
    'late execution error cannot affect another request or a later visit',
    () async {
      await m.load();
      await m.decide(WorkspaceApprovalAction.approve);
      s.demonstrateApprovalExecutions('server');
      await m.load();
      final old = m.detail!.executions.last,
          delayed = Completer<WorkspaceApprovalExecution>();
      port.executionOverride = (_, _) => delayed.future;
      final lookup = m.refreshExecution(old.operationId);
      expect(m.readingExecution(old.operationId), true);
      await m.select('token');
      await m.select('server');
      var newQueries = 0;
      port.executionOverride = (request, operation) {
        newQueries++;
        return port.inner.execution(request, operation);
      };
      await m.refreshExecution(old.operationId);
      expect(newQueries, 1);
      delayed.completeError(const WorkspaceFailure('offline', '旧查询失败'));
      await lookup;
      expect(m.detail!.request.id, 'server');
      expect(m.executionError(old.operationId), isNull);
      expect(
        m.detail!.executions.last.observationDigest,
        old.observationDigest,
      );
      expect(m.executionError(old.operationId), isNull);
      expect(m.readingExecution(old.operationId), false);
    },
  );

  test(
    'request-specific conflict does not block a different result and terminal selections use the approved members',
    () async {
      await m.load();
      final original = Set.of(m.draft!.selected);
      m.writeFailure = const WorkspaceFailure('conflict', '原请求变化');
      await m.search('仓库');
      expect(m.selection, 'token');
      expect(m.canDecide, true);
      await m.open('server');
      final d = m.detail!,
          host = d.scopes.firstWhere((x) => x.fieldKey == 'host');
      await s.approvals.change(
        WorkspaceApprovalChange(
          operationId: 'other-owner',
          requestId: 'server',
          reviewToken: d.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: [host.id],
        ),
      );
      await m.select('token');
      await m.select('server');
      expect(m.draft!.selected, {host.id});
      expect(m.draft!.selected, isNot(original));
      m.writeFailure = const WorkspaceFailure('conflict', '旧错误');
      m.resetView();
      await m.load();
      expect(m.writeFailure, isNull);
      expect(m.notice, isNull);
    },
  );
}
