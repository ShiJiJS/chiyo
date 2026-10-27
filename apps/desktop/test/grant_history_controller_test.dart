import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

class _History implements WorkspaceGrantHistorySource {
  _History(this.inner);
  final WorkspaceGrantHistorySource inner;
  Future<WorkspaceGrantResults> Function(WorkspaceGrantQuery, String?)?
  queryOverride;
  Future<WorkspaceGrantDetail> Function(String)? readOverride;
  @override
  Future<WorkspaceGrantResults> query(
    WorkspaceGrantQuery q, {
    String? keepSelection,
  }) =>
      queryOverride?.call(q, keepSelection) ??
      inner.query(q, keepSelection: keepSelection);
  @override
  Future<WorkspaceGrantDetail> read(String id) =>
      readOverride?.call(id) ?? inner.read(id);
  @override
  Future<WorkspaceArchive> snapshot(String id, WorkspaceRecordRef ref) =>
      inner.snapshot(id, ref);
  @override
  Future<WorkspaceFilePreview> filePreview(
    String id,
    String scope, {
    int page = 0,
  }) => inner.filePreview(id, scope, page: page);
}

class _Approvals implements WorkspaceApprovalSource {
  _Approvals(this.inner);
  final WorkspaceApprovalSource inner;
  bool absent = false, receiptFailure = false;
  int writes = 0;
  final commands = <WorkspaceApprovalChange>[];
  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange c) {
    writes++;
    commands.add(c);
    if (absent) {
      return Future.error(const WorkspaceFailure('unknown_outcome', '结果未知'));
    }
    return inner.change(c);
  }

  @override
  Future<WorkspaceApprovalReceipt?> receipt(String id) {
    if (receiptFailure) {
      return Future.error(const WorkspaceFailure('unavailable', '查询失败'));
    }
    return inner.receipt(id);
  }

  @override
  Future<WorkspaceApprovalDetail> read(String id) => inner.read(id);
  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery q, {
    String? keepSelection,
  }) => inner.query(q, keepSelection: keepSelection);
  @override
  Future<WorkspaceApprovalExecution> execution(String id, String operation) =>
      inner.execution(id, operation);
}

void main() {
  late SampleWorkspaceSource s;
  late _History history;
  late _Approvals approval;
  late GrantHistoryController m;
  setUp(() async {
    s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes());
    await s.approvals.change(decision(await s.approvals.read('server')));
    await s.approvals.change(decision(await s.approvals.read('token')));
    history = _History(s.grantHistory);
    approval = _Approvals(s.approvals);
    m = GrantHistoryController(history, approval, const Stream.empty());
  });
  tearDown(() {
    m.dispose();
    s.dispose();
  });

  test(
    'late list and detail replies never replace a newer history selection',
    () async {
      await m.open('request:server');
      final query = Completer<WorkspaceGrantResults>();
      history.queryOverride = (_, _) => query.future;
      final stale = m.load();
      history.queryOverride = null;
      await m.select('request:token');
      query.completeError(const WorkspaceFailure('offline', '旧查询失败'));
      await stale;
      expect(m.selection, 'request:token');
      expect(m.readFailure, isNull);
      final read = Completer<WorkspaceGrantDetail>();
      history.readOverride = (id) =>
          id == 'request:server' ? read.future : history.inner.read(id);
      final staleRead = m.select('request:server');
      // Let the source query reach the deliberately held detail read.
      await Future<void>.delayed(Duration.zero);
      await m.select('request:token');
      read.complete(await history.inner.read('request:server'));
      await staleRead;
      expect(m.detail!.summary.id, 'request:token');
      expect(m.linkedDecision, true);
      expect(m.canRevoke, true);
    },
  );

  test(
    'paging keeps stable identity, active expiry retains the selected record and exact deadlines',
    () async {
      m.limit = 1;
      await m.open('request:server');
      expect(m.results!.items.single.id, 'request:server');
      await m.setFilter(WorkspaceGrantFilter.active);
      await m.select('request:server');
      final end = m.detail!.credentialExpiresAt;
      s.advanceApprovalClock(const Duration(hours: 1));
      await m.load();
      expect(m.filter, WorkspaceGrantFilter.all);
      expect(m.selection, 'request:server');
      expect(m.detail!.summary.state, WorkspaceGrantState.expired);
      expect(m.detail!.credentialExpiresAt, end);
      expect(m.canRevoke, false);
      expect(m.notice, contains('已结束'));
    },
  );

  test(
    'lost revoke reply freezes intent and navigation until original receipt resolves; never replays',
    () async {
      await m.open('request:server');
      m.detailScroll = 160;
      s.loseNextApprovalReply = true;
      await m.revoke();
      expect(m.frozen, true);
      expect(approval.writes, 1);
      expect(m.detailScroll, 160);
      await m.select('request:token');
      await m.search('other');
      expect(m.selection, 'request:server');
      approval.receiptFailure = true;
      await m.reconcile();
      expect(m.frozen, true);
      approval.receiptFailure = false;
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.detail!.summary.state, WorkspaceGrantState.revoked);
      expect(approval.writes, 1);
      expect(approval.commands.single.action, WorkspaceApprovalAction.revoke);
      expect(m.canRevoke, false);
    },
  );

  test(
    'confirmed absence permits an explicit new revoke but does not retry automatically',
    () async {
      await m.open('request:server');
      approval.absent = true;
      await m.revoke();
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.canRevoke, true);
      expect(m.detail!.summary.state, WorkspaceGrantState.active);
      expect(approval.writes, 1);
      approval.absent = false;
      await m.revoke();
      expect(approval.writes, 2);
      expect(
        approval.commands.last.operationId,
        isNot(approval.commands.first.operationId),
      );
      expect(m.detail!.summary.state, WorkspaceGrantState.revoked);
    },
  );

  test(
    'failed refresh preserves old detail and positions while disabling stale revoke until explicit reread',
    () async {
      await m.open('request:server');
      m.listScroll = 43;
      m.detailScroll = 140;
      history.readOverride = (_) =>
          Future.error(const WorkspaceFailure('offline', '读取失败'));
      await m.load();
      expect(m.detail!.summary.id, 'request:server');
      expect(m.listScroll, 43);
      expect(m.detailScroll, 140);
      expect(m.canRevoke, false);
      history.readOverride = null;
      await m.load(review: true);
      expect(m.canRevoke, true);
      expect(m.listScroll, 43);
    },
  );
}
