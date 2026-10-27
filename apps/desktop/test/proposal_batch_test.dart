import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/proposal_batch.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_proposals_test.dart' show proposalChange, editedReview;

class _BatchPort implements WorkspaceProposalSource {
  _BatchPort(this.inner);
  final WorkspaceProposalSource inner;
  final commands = <WorkspaceProposalChange>[];
  final lookups = <String>[];
  final reads = <String>[];
  final failures = <String, WorkspaceFailure>{};
  final absent = <String>{};
  bool wrongReceipt = false, lookupFails = false, throwAfterCommit = false;
  Future<WorkspaceProposalDetail> Function(String)? readOverride;
  @override
  Future<WorkspaceProposalDetail> read(String id) {
    reads.add(id);
    return readOverride?.call(id) ?? inner.read(id);
  }

  Future<WorkspaceProposalResults> Function(WorkspaceProposalQuery, String?)?
  queryOverride;
  WorkspaceProposalReceipt _receipt(WorkspaceProposalReceipt r) => wrongReceipt
      ? WorkspaceProposalReceipt(
          operationId: r.operationId,
          proposalId: r.proposalId,
          action: r.action,
          reviewToken: r.reviewToken,
          reviewedVersion: r.reviewedVersion,
          resultingVersion: r.resultingVersion,
          commandDigest: 'not-this-command',
          records: r.records,
        )
      : r;
  @override
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange c) async {
    commands.add(c);
    if (failures.remove(c.proposalId) case final failure?) throw failure;
    if (absent.contains(c.proposalId)) {
      throw const WorkspaceFailure('unknown_outcome', '结果未知');
    }
    final r = await inner.change(c);
    if (throwAfterCommit) throw StateError('connection lost after commit');
    return _receipt(r);
  }

  @override
  Future<WorkspaceProposalReceipt?> receipt(String id) async {
    lookups.add(id);
    if (lookupFails) throw const WorkspaceFailure('offline', '查询失败');
    final r = await inner.receipt(id);
    return r == null ? null : _receipt(r);
  }

  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery q, {
    String? keepSelection,
  }) =>
      queryOverride?.call(q, keepSelection) ??
      inner.query(q, keepSelection: keepSelection);
  @override
  Future<WorkspaceCatalog> catalog() => inner.catalog();
  @override
  WorkspaceRelationSource relations(String p, String i, int v) =>
      inner.relations(p, i, v);
  @override
  Future<WorkspaceArchive> snapshot(String p, WorkspaceRecordRef r) =>
      inner.snapshot(p, r);
  @override
  Future<WorkspaceDetail> currentTarget(String p) => inner.currentTarget(p);
}

void main() {
  late SampleWorkspaceSource s;
  late _BatchPort port;
  late ProposalBatch batch;
  final handled = <String>[];
  setUp(() {
    s = SampleWorkspaceSource();
    port = _BatchPort(s.proposals);
    handled.clear();
    batch = ProposalBatch(port, onHandled: handled.add);
  });
  tearDown(() {
    batch.dispose();
    s.dispose();
  });
  Future<void> stage(
    String id, {
    WorkspaceProposalAction action = WorkspaceProposalAction.confirm,
  }) async {
    final d = await s.proposals.read(id);
    expect(batch.stage(d, proposalChange(d, action: action)), true);
  }

  test(
    'mixed addition, correction and deletion keep independent receipts and never retain successful submitted bodies',
    () async {
      await s.demonstrateDeletionProposal();
      final count = (await s.loadSummary()).records;
      for (final id in ['import', 'update', 'delete-service']) {
        await stage(id);
      }
      await batch.runPending();
      expect(
        batch.entries.map((e) => e.status),
        everyElement(ProposalBatchStatus.completed),
      );
      expect(
        batch.entries.every((e) => e.command == null && e.receipt != null),
        true,
      );
      expect(port.commands.map((c) => c.proposalId), [
        'import',
        'update',
        'delete-service',
      ]);
      expect(port.commands.map((c) => c.operationId).toSet(), hasLength(3));
      expect((await s.loadSummary()).records, count + 1);
      expect(handled, ['import', 'update', 'delete-service']);
      await batch.runPending();
      expect(port.commands, hasLength(3));
    },
  );
  test(
    'a later conflict and definitive failure preserve earlier commits; explicit retry writes only its own failed item',
    () async {
      await s.demonstrateDeletionProposal();
      for (final id in ['import', 'update', 'delete-service']) {
        await stage(id);
      }
      final current = await s.proposals.currentTarget('update');
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'other-owner',
          expectedVersion: current.version,
          record: current.record,
          values: {'port': '2200'},
        ),
      );
      port.failures['delete-service'] = const WorkspaceFailure(
        'disk_full',
        '无法保存',
      );
      await batch.runPending();
      expect(batch.entries.map((e) => e.status).toList(), [
        ProposalBatchStatus.completed,
        ProposalBatchStatus.conflict,
        ProposalBatchStatus.failed,
      ]);
      expect(
        batch.entry('update')!.command!.reviewed.single.values['port'],
        '2222',
      );
      expect(
        (await s.proposals.currentTarget('update')).values['port'],
        '2200',
      );
      final oldOperation = batch.entry('delete-service')!.command!.operationId;
      await batch.retry('delete-service');
      expect(
        batch.entry('delete-service')!.status,
        ProposalBatchStatus.completed,
      );
      expect(
        port.commands.where((c) => c.proposalId == 'import'),
        hasLength(1),
      );
      expect(port.commands.where((c) => c.proposalId == 'update'), isEmpty);
      expect(port.commands.last.operationId, isNot(oldOperation));
    },
  );
  test(
    'middle unknown stops only the unstarted tail; receipt failure or mismatch never writes and successful lookup does not automatically continue',
    () async {
      await s.demonstrateFieldProposals();
      for (final id in ['import', 'fields-server', 'delete-field']) {
        await stage(id);
      }
      s.loseReplyForProposal('fields-server');
      await batch.runPending();
      expect(batch.entries.map((e) => e.status).toList(), [
        ProposalBatchStatus.completed,
        ProposalBatchStatus.unknown,
        ProposalBatchStatus.notStarted,
      ]);
      expect(batch.frozen, true);
      port.lookupFails = true;
      await batch.reconcile();
      expect(batch.uncertain, true);
      port.lookupFails = false;
      port.wrongReceipt = true;
      await batch.reconcile();
      expect(batch.uncertain, true);
      expect(port.commands, hasLength(2));
      port.wrongReceipt = false;
      await batch.reconcile();
      expect(batch.frozen, false);
      expect(batch.entry('fields-server')!.command, isNull);
      expect(
        batch.entry('delete-field')!.status,
        ProposalBatchStatus.notStarted,
      );
      expect(port.commands, hasLength(2));
      await batch.runPending();
      expect(
        batch.entries.every((e) => e.status == ProposalBatchStatus.completed),
        true,
      );
      expect(port.commands, hasLength(3));
    },
  );
  test(
    'confirmed absence requires an explicit fresh operation and leaves the remaining original plan untouched',
    () async {
      await s.demonstrateFieldProposals();
      for (final id in ['import', 'fields-server', 'delete-field']) {
        await stage(id);
      }
      port.absent.add('fields-server');
      await batch.runPending();
      final old = batch.entry('fields-server')!.command!;
      await batch.reconcile();
      expect(
        batch.entry('fields-server')!.status,
        ProposalBatchStatus.notSubmitted,
      );
      expect(port.commands, hasLength(2));
      port.absent.clear();
      await batch.retry('fields-server');
      expect(port.commands.last.operationId, isNot(old.operationId));
      expect(port.commands.last.digest, isNot(old.digest));
      expect(batch.pendingCount, 1);
      expect((await s.proposals.read('delete-field')).summary.pending, true);
    },
  );
  test(
    'changed submitted meaning cannot silently rebind a frozen review even with the same ID and version',
    () async {
      await stage('import');
      final old = await s.proposals.read('import'), item = old.items.first;
      port.readOverride = (_) async => WorkspaceProposalDetail(
        summary: old.summary,
        reviewToken: old.reviewToken,
        items: [
          WorkspaceProposalItem(
            id: item.id,
            proposed: WorkspaceDetail(
              record: item.proposed.record,
              version: 0,
              definition: {...item.proposed.definition, 'name': '另一种含义'},
              values: item.proposed.values,
            ),
          ),
          ...old.items.skip(1),
        ],
      );
      await batch.runPending();
      expect(batch.entries.single.status, ProposalBatchStatus.conflict);
      expect(batch.entries.single.command!.reviewed, hasLength(2));
      expect(port.commands, isEmpty);
    },
  );
  test(
    'an externally handled proposal releases obsolete bodies without claiming this batch submitted it',
    () async {
      await stage('import');
      await s.proposals.change(
        proposalChange(
          await s.proposals.read('import'),
          action: WorkspaceProposalAction.reject,
        ),
      );
      await batch.runPending();
      expect(batch.entries.single.status, ProposalBatchStatus.obsolete);
      expect(batch.entries.single.command, isNull);
      expect(batch.entries.single.receipt, isNull);
      expect(port.commands, isEmpty);
    },
  );
  test(
    'an unexpected exception after commit remains unknown and resolves from the original receipt without replay',
    () async {
      await stage('import');
      port.throwAfterCommit = true;
      await batch.runPending();
      expect(batch.uncertain, true);
      await batch.reconcile();
      expect(batch.entries.single.status, ProposalBatchStatus.completed);
      expect(port.commands, hasLength(1));
    },
  );
  test(
    'controller freezes native-facing navigation for a batch unknown, keeps explicit queued edits and clears terminal drafts',
    () async {
      final m = ProposalsController(s.proposals, s.changes);
      addTearDown(m.dispose);
      await m.open('import');
      m.chooseItem('status', false);
      m.editItem(
        'import',
        1,
        editedReview(m.draft!.items['portal']!, name: '已加入清单的名称'),
      );
      expect(m.queueForBatch(WorkspaceProposalAction.confirm), true);
      m.editItem(
        'import',
        1,
        editedReview(m.draft!.items['portal']!, name: '尚未更新清单的编辑'),
      );
      expect(
        m.batch.entry('import')!.command!.reviewed.single.name,
        '已加入清单的名称',
      );
      s.loseNextProposalReply = true;
      await m.batch.runPending();
      expect(m.frozen, true);
      await m.select('update');
      m.resetView();
      expect(m.selection, 'import');
      await m.batch.reconcile();
      for (var i = 0; i < 50 && (m.loading || m.reading); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(m.frozen, false);
      expect(m.draft, isNull);
      expect(m.batch.entry('import')!.command, isNull);
    },
  );
  test(
    'batch result reading returns to the original query, page, selection and list position',
    () async {
      final m = ProposalsController(s.proposals, const Stream.empty());
      addTearDown(m.dispose);
      m.limit = 1;
      await m.search('服务器');
      await m.select('update');
      expect(m.offset, 1);
      final selected = m.selection;
      m.listScroll = 83;
      m.detailScroll = 140;
      m.rememberBatchLocation();
      await m.openBatchResult('import');
      expect(m.keyword, '');
      expect(m.selection, 'import');
      await m.returnBatchLocation();
      expect(m.keyword, '服务器');
      expect(m.selection, selected);
      expect(m.listScroll, 83);
      expect(m.detailScroll, 140);
      expect(m.hasBatchLocation, false);
    },
  );
  test(
    'hidden queued terminal review is released from metadata without reading bodies or claiming a batch receipt',
    () async {
      await stage('import');
      await stage('update');
      final original = batch.entry('import')!;
      final d = await s.proposals.read('import');
      await s.proposals.change(
        proposalChange(d, action: WorkspaceProposalAction.reject),
      );
      await batch.refreshMetadata();
      expect(original.status, ProposalBatchStatus.obsolete);
      expect(original.command, isNull);
      expect(original.receipt, isNull);
      expect(batch.entry('update')!.status, ProposalBatchStatus.notStarted);
      expect(batch.entry('update')!.command, isNotNull);
      expect(handled, ['import']);
      expect(port.reads, isEmpty);
      expect(port.commands, isEmpty);
    },
  );
  test(
    'late metadata cannot resolve an unknown submission or replace its original operation lookup',
    () async {
      await stage('import');
      final pending = Completer<WorkspaceProposalResults>();
      port.queryOverride = (_, _) => pending.future;
      final refreshing = batch.refreshMetadata();
      s.loseNextProposalReply = true;
      await batch.runPending();
      expect(batch.uncertain, true);
      pending.complete(
        await s.proposals.query(
          const WorkspaceProposalQuery(limit: 1),
          keepSelection: 'import',
        ),
      );
      await refreshing;
      expect(batch.entry('import')!.status, ProposalBatchStatus.unknown);
      expect(batch.entry('import')!.command, isNotNull);
      expect(port.lookups, isEmpty);
      await batch.reconcile();
      expect(batch.entry('import')!.status, ProposalBatchStatus.completed);
      expect(port.commands, hasLength(1));
      expect(port.lookups, hasLength(1));
    },
  );
  test(
    'disposing during preflight prevents late writes and does not resume another proposal',
    () async {
      await stage('import');
      await stage('update');
      final pending = Completer<WorkspaceProposalDetail>();
      port.readOverride = (_) => pending.future;
      final running = batch.runPending();
      batch.dispose();
      // Replace the tearDown target rather than disposing an object twice.
      batch = ProposalBatch(port, onHandled: handled.add);
      pending.complete(await s.proposals.read('import'));
      await running;
      expect(port.commands, isEmpty);
      expect(handled, isEmpty);
    },
  );
}
