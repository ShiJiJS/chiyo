import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Port implements WorkspaceApprovalSource {
  _Port(this.inner);
  final WorkspaceApprovalSource inner;
  Future<WorkspaceApprovalDetail> Function(String)? readOverride;
  Future<WorkspaceApprovalResults> Function(WorkspaceApprovalQuery, String?)?
  queryOverride;
  bool loseWithoutCommit = false, wrongDigest = false;
  int writes = 0;
  final commands = <WorkspaceApprovalChange>[];
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
}
