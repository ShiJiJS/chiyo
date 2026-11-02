import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_proposals_test.dart' show editedReview;

class _Port implements WorkspaceProposalSource {
  _Port(this.inner);
  final WorkspaceProposalSource inner;
  Future<WorkspaceProposalResults> Function(WorkspaceProposalQuery, String?)?
  queryOverride;
  Future<WorkspaceProposalDetail> Function(String)? readOverride;
  bool absent = false,
      wrongDigest = false,
      missingRecycleEntry = false,
      lookupFailure = false,
      failTerminalRead = false;
  final commands = <WorkspaceProposalChange>[];
  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery q, {
    String? keepSelection,
  }) =>
      queryOverride?.call(q, keepSelection) ??
      inner.query(q, keepSelection: keepSelection);
  @override
  Future<WorkspaceProposalDetail> read(String id) async {
    if (readOverride != null) return readOverride!(id);
    final d = await inner.read(id);
    if (failTerminalRead && !d.summary.pending) {
      throw const WorkspaceFailure('offline', '结果详情暂时无法读取');
    }
    return d;
  }

  WorkspaceProposalReceipt _wrong(WorkspaceProposalReceipt r) =>
      WorkspaceProposalReceipt(
        operationId: r.operationId,
        proposalId: r.proposalId,
        action: r.action,
        reviewToken: r.reviewToken,
        reviewedVersion: r.reviewedVersion,
        resultingVersion: r.resultingVersion,
        commandDigest: wrongDigest ? 'another-command' : r.commandDigest,
        records: missingRecycleEntry
            ? r.records.map(
                (x) => WorkspaceRecordReceipt(ref: x.ref, version: x.version),
              )
            : r.records,
      );
  @override
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange c) async {
    commands.add(c);
    if (absent) throw const WorkspaceFailure('unknown_outcome', '结果未知');
    final r = await inner.change(c);
    return wrongDigest || missingRecycleEntry ? _wrong(r) : r;
  }

  @override
  Future<WorkspaceProposalReceipt?> receipt(String id) async {
    if (lookupFailure) throw const WorkspaceFailure('offline', '查询失败');
    final r = await inner.receipt(id);
    return (wrongDigest || missingRecycleEntry) && r != null ? _wrong(r) : r;
  }

  @override
  WorkspaceRelationSource relations(String id, String item, int version) =>
      inner.relations(id, item, version);
  @override
  Future<WorkspaceCatalog> catalog() => inner.catalog();
  @override
  Future<WorkspaceArchive> snapshot(String id, WorkspaceRecordRef ref) =>
      inner.snapshot(id, ref);
  @override
  Future<WorkspaceDetail> currentTarget(String id) => inner.currentTarget(id);
}

void main() {
  late SampleWorkspaceSource s;
  late _Port port;
  late ProposalsController m;
  setUp(() {
    s = SampleWorkspaceSource();
    port = _Port(s.proposals);
    m = ProposalsController(port, const Stream.empty());
  });
  tearDown(() {
    m.dispose();
    s.dispose();
  });
  test(
    'each proposal retains its own edits, selection and reading position across pages and query changes',
    () async {
      m.limit = 1;
      await m.open('import');
      final first = m.draft!.items['portal']!;
      m.editItem('import', 1, editedReview(first, name: 'Owner审阅名称'));
      m.chooseItem('status', false);
      m.detailScroll = 135;
      await m.select('update');
      expect(m.offset, 1);
      m.detailScroll = 244;
      await m.select('import');
      expect(m.offset, 0);
      expect(m.draft!.items['portal']!.name, 'Owner审阅名称');
      expect(m.draft!.selected, {'portal'});
      expect(m.detailScroll, 135);
      await m.select('update');
      expect(m.detailScroll, 244);
      await m.search('北辰');
      expect(m.detail!.summary.id, 'import');
      expect(m.draft!.items['portal']!.name, 'Owner审阅名称');
      expect(port.commands, isEmpty);
    },
  );
  test(
    'late metadata and body reads cannot replace the newer selected proposal or its draft',
    () async {
      await m.open('import');
      final query = Completer<WorkspaceProposalResults>();
      port.queryOverride = (_, _) => query.future;
      final old = m.load();
      port.queryOverride = null;
      await m.select('update');
      query.completeError(const WorkspaceFailure('offline', '旧列表失败'));
      await old;
      expect(m.detail!.summary.id, 'update');
      expect(m.readFailure, isNull);
      final read = Completer<WorkspaceProposalDetail>();
      port.readOverride = (id) =>
          id == 'import' ? read.future : port.inner.read(id);
      final stale = m.select('import');
      await Future<void>.delayed(Duration.zero);
      await m.select('update');
      read.complete(await port.inner.read('import'));
      await stale;
      expect(m.detail!.summary.id, 'update');
      expect(m.canConfirm, true);
    },
  );
  test(
    'lost reply freezes the exact review until original receipt resolves without a second write',
    () async {
      await m.open('import');
      m.chooseItem('status', false);
      final review = m.draft!.items['portal']!;
      m.editItem('import', 1, editedReview(review, name: '未知结果审阅'));
      s.loseNextProposalReply = true;
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.uncertain, true);
      expect(port.commands, hasLength(1));
      await m.select('update');
      await m.search('other');
      m.chooseItem('status', true);
      expect(m.selection, 'import');
      expect(m.draft!.selected, {'portal'});
      port.lookupFailure = true;
      await m.reconcile();
      expect(m.frozen, true);
      port.lookupFailure = false;
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(m.draft, isNull);
      expect(m.detail!.items, isEmpty);
      expect(port.commands, hasLength(1));
      expect(
        (await s.readDetail(m.detail!.targets.single.record)).record.name,
        '未知结果审阅',
      );
    },
  );
  test(
    'confirmed absence preserves input and only an explicit new decision retries it',
    () async {
      await m.open('import');
      m.chooseItem('status', false);
      m.detailScroll = 113;
      port.absent = true;
      await m.decide(WorkspaceProposalAction.confirm);
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.canConfirm, true);
      expect(m.draft!.selected, {'portal'});
      expect(m.detailScroll, 113);
      expect(port.commands, hasLength(1));
      port.absent = false;
      await m.decide(WorkspaceProposalAction.confirm);
      expect(port.commands, hasLength(2));
      expect(
        port.commands.last.operationId,
        isNot(port.commands.first.operationId),
      );
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
    },
  );
  test(
    'automatic selection of another proposal clears prior confirmation feedback',
    () async {
      await m.open('update');
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.notice, contains('已记录'));
      port.queryOverride = (q, keep) async {
        final result = await port.inner.query(q);
        return WorkspaceProposalResults(
          items: result.items,
          total: result.total,
          pending: result.pending,
          offset: result.offset,
          selection: 'import',
        );
      };
      await m.load();
      expect(m.detail!.summary.id, 'import');
      expect(m.notice, isNull);
    },
  );
  test(
    'mismatched command digest remains unknown until matching original receipt, never replays',
    () async {
      await m.open('update');
      port.wrongDigest = true;
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.frozen, true);
      await m.reconcile();
      expect(m.frozen, true);
      expect(port.commands, hasLength(1));
      port.wrongDigest = false;
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(port.commands, hasLength(1));
    },
  );
  test(
    'successful commit clears reviewed bodies even when terminal detail read fails; retry only reads',
    () async {
      await m.open('import');
      port.failTerminalRead = true;
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.readFailure, isNotNull);
      expect(m.detail, isNull);
      expect(m.draft, isNull);
      expect(m.uncertain, false);
      expect(m.notice, contains('已记录'));
      port.failTerminalRead = false;
      await m.load();
      expect(m.detail!.items, isEmpty);
      expect(m.detail!.targets, hasLength(2));
      expect(port.commands, hasLength(1));
    },
  );
  test(
    'conflict preserves edited proposal values, explicit reread never rebases its target, rejection leaves current body intact',
    () async {
      await m.open('update');
      final old = m.draft!.items.values.single;
      m.editItem(
        'update',
        1,
        editedReview(old, values: {...old.values, 'port': '2233'}),
      );
      final target = await s.proposals.currentTarget('update');
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'concurrent',
          expectedVersion: target.version,
          record: target.record,
          values: {'port': '2200'},
        ),
      );
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.writeFailure!.code, 'conflict');
      expect(m.draft!.items.values.single.values['port'], '2233');
      await m.reviewCurrent();
      expect(m.canConfirm, false);
      expect(m.canReject, true);
      expect(m.detail!.items.single.before!.version, target.version);
      expect(m.draft!.items.values.single.values['port'], '2233');
      await m.decide(WorkspaceProposalAction.reject);
      expect(m.draft, isNull);
      expect((await s.readDetail(target.record.ref)).values['port'], '2200');
    },
  );
  test(
    'changed pending content with the same IDs cannot reinterpret or rebind the old Owner draft',
    () async {
      await m.open('import');
      final original = m.detail!, old = original.items.first;
      m.editItem(
        'import',
        1,
        editedReview(m.draft!.items[old.id]!, name: '旧审阅的名称'),
      );
      port.readOverride = (_) async => WorkspaceProposalDetail(
        summary: original.summary,
        reviewToken: original.reviewToken,
        items: [
          WorkspaceProposalItem(
            id: old.id,
            proposed: WorkspaceDetail(
              record: old.proposed.record.copyWith(name: '另一份新含义资料'),
              version: old.proposed.version,
              definition: {...old.proposed.definition, 'name': '改变了含义的结构'},
              values: old.proposed.values,
              relations: old.proposed.relations,
            ),
          ),
          ...original.items.skip(1),
        ],
      );
      await m.load();
      expect(m.needsNewReview, true);
      expect(m.canConfirm, false);
      expect(m.canEdit, false);
      expect(m.reviewItems.first.proposed.definition, old.proposed.definition);
      await m.reviewCurrent();
      expect(m.writeFailure!.code, 'conflict');
      expect(m.canConfirm, false);
      expect(m.draft!.items[old.id]!.name, '旧审阅的名称');
      expect(port.commands, isEmpty);
    },
  );
  test(
    'Owner before-value observations invalidate even while the exact write intent remains unknown',
    () async {
      final live = ProposalsController(port, s.changes);
      addTearDown(live.dispose);
      await live.open('update');
      expect(live.detail!.items.single.before!.values.keys, ['port']);
      expect(live.draft!.originals.values.single.before!.values, isEmpty);
      expect(live.draft!.items.values.single.values.keys, ['port']);
      s.loseNextProposalReply = true;
      await live.decide(WorkspaceProposalAction.confirm);
      await Future<void>.delayed(Duration.zero);
      expect(live.uncertain, true);
      expect(live.detail!.items.single.before!.values, isEmpty);
      expect(
        live.detail!.items.single.beforeState,
        WorkspaceProposalBeforeState.unread,
      );
      final current = await s.proposals.currentTarget('update');
      final deleted = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'unknown-target-recycle',
          ref: current.record.ref,
          expectedVersion: current.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'unknown-target-purge',
          ref: current.record.ref,
          expectedVersion: deleted.version,
          entryId: deleted.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(live.frozen, true);
      expect(live.detail!.items.single.before!.values, isEmpty);
      expect(live.draft!.items.values.single.values['port'], '2222');
      await live.reconcile();
      expect(live.frozen, false);
      expect(live.detail!.items, isEmpty);
      expect(live.draft, isNull);
      expect(live.detail!.targets.single.snapshotAvailable, false);
      expect(port.commands, hasLength(1));
    },
  );
  test(
    'deletion review has no editor or cached old body; unknown clearing does not change the fixed proposal meaning',
    () async {
      await s.demonstrateDeletionProposal();
      final live = ProposalsController(port, s.changes);
      addTearDown(live.dispose);
      await live.open('delete-service');
      expect(live.canConfirm, true);
      expect(live.canEdit, false);
      expect(live.detail!.items.single.before!.relations, isNotEmpty);
      expect(live.draft!.originals.values.single.before!.values, isEmpty);
      expect(live.draft!.originals.values.single.before!.relations, isEmpty);
      s.loseNextProposalReply = true;
      await live.decide(WorkspaceProposalAction.confirm);
      await Future<void>.delayed(Duration.zero);
      expect(live.uncertain, true);
      expect(live.detail!.items.single.before!.values, isEmpty);
      expect(live.detail!.items.single.before!.relations, isEmpty);
      expect(live.needsNewReview, false);
      await live.reconcile();
      expect(live.frozen, false);
      expect(live.draft, isNull);
      expect(live.detail!.targets.single.exists, false);
      expect(live.detail!.targets.single.snapshotAvailable, true);
      expect(port.commands, hasLength(1));
    },
  );
  test(
    'deletion receipt without a recycle identity remains unknown until the original complete receipt is read',
    () async {
      await s.demonstrateDeletionProposal();
      await m.open('delete-service');
      port.missingRecycleEntry = true;
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.uncertain, true);
      expect(port.commands, hasLength(1));
      port.missingRecycleEntry = false;
      await m.reconcile();
      expect(m.frozen, false);
      expect(m.detail!.targets.single.exists, false);
      expect(port.commands, hasLength(1));
    },
  );
}
