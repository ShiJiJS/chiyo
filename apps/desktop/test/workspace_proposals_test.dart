import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

WorkspaceProposalChange proposalChange(
  WorkspaceProposalDetail d, {
  String? operation,
  WorkspaceProposalAction action = WorkspaceProposalAction.confirm,
  List<WorkspaceProposalItemReview>? reviewed,
}) => WorkspaceProposalChange(
  operationId: operation ?? workspaceOperationId(),
  proposalId: d.summary.id,
  version: d.summary.version,
  reviewToken: d.reviewToken,
  action: action,
  reviewed: action == WorkspaceProposalAction.reject
      ? []
      : reviewed ?? d.items.map(WorkspaceProposalItemReview.fromItem).toList(),
);
WorkspaceProposalItemReview editedReview(
  WorkspaceProposalItemReview r, {
  String? name,
  Map<String, Object?>? values,
}) => WorkspaceProposalItemReview(
  itemId: r.itemId,
  name: name ?? r.name,
  description: r.description,
  directoryId: r.directoryId,
  tagIds: r.tagIds,
  values: values ?? r.values,
  relations: r.relations,
);
Matcher proposalFailure(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  late SampleWorkspaceSource s;
  setUp(() => s = SampleWorkspaceSource());
  tearDown(() => s.dispose());
  test(
    'one queue supplies metadata filters, stable pagination and pending counts without indexing private values',
    () async {
      final q = await s.proposals.query(
        const WorkspaceProposalQuery(limit: 1),
        keepSelection: 'update',
      );
      expect(q.pending, 2);
      expect(q.total, 2);
      expect(q.selection, 'update');
      expect(q.selectionIndex, 1);
      expect((await s.loadSummary()).proposals, 2);
      expect(
        (await s.proposals.query(
          const WorkspaceProposalQuery(keyword: 'portal.beichen.example'),
        )).total,
        0,
      );
      expect(
        (await s.proposals.query(
          const WorkspaceProposalQuery(
            kind: WorkspaceProposalKind.modification,
          ),
        )).items.single.id,
        'update',
      );
      final d = await s.proposals.read('import');
      expect(d.items, hasLength(2));
      expect(d.canConfirm, true);
      expect(
        d.items.every(
          (i) => i.proposed.record.ref.id.startsWith('proposal-draft:'),
        ),
        true,
      );
      expect(
        () => d.items.first.proposed.values['url'] = 'overwrite',
        throwsUnsupportedError,
      );
      final review = WorkspaceProposalItemReview.fromItem(d.items.first);
      expect(
        () => review.relations['hostedOn']!.clear(),
        throwsUnsupportedError,
      );
      await expectLater(
        s.proposals.query(const WorkspaceProposalQuery(limit: 101)),
        proposalFailure('invalid_query'),
      );
    },
  );
  test(
    'one import commits all reviewed items atomically; invalid later item and write failure commit none',
    () async {
      final d = await s.proposals.read('import'),
          reviews = d.items.map(WorkspaceProposalItemReview.fromItem).toList();
      final before = (await s.loadSummary()).records;
      await expectLater(
        s.proposals.change(
          proposalChange(
            d,
            reviewed: [
              reviews.first,
              editedReview(reviews.last, name: ''),
            ],
          ),
        ),
        proposalFailure('validation'),
      );
      expect((await s.loadSummary()).records, before);
      expect((await s.proposals.read('import')).summary.pending, true);
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '存储空间不足');
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('disk_full'),
      );
      expect((await s.loadSummary()).records, before);
      final c = proposalChange(d), receipt = await s.proposals.change(c);
      expect(receipt.commandDigest, c.digest);
      expect(receipt.records, hasLength(2));
      expect((await s.loadSummary()).records, before + 2);
      expect((await s.loadSummary()).proposals, 1);
      for (final r in receipt.records) {
        final detail = await s.readDetail(r.ref);
        expect(detail.version, r.version);
        expect(detail.fieldIds, hasLength(3));
      }
      expect(await s.proposals.change(c), same(receipt));
      expect((await s.proposals.read('import')).items, isEmpty);
      expect((await s.proposals.read('import')).targets, hasLength(2));
      await expectLater(
        s.proposals.change(
          proposalChange(
            d,
            operation: c.operationId,
            reviewed: [reviews.first],
          ),
        ),
        proposalFailure('operation_conflict'),
      );
      expect((await s.loadSummary()).records, before + 2);
    },
  );
  test(
    'explicit item selection and rejection change only their intended proposal',
    () async {
      final d = await s.proposals.read('import'),
          selected = WorkspaceProposalItemReview.fromItem(d.items.first);
      final receipt = await s.proposals.change(
        proposalChange(
          d,
          reviewed: [editedReview(selected, name: 'Owner核对后的入口')],
        ),
      );
      expect(receipt.records, hasLength(1));
      expect(
        (await s.readDetail(receipt.records.single.ref)).record.name,
        'Owner核对后的入口',
      );
      expect((await s.proposals.read('import')).summary.itemCount, 1);
      final before = (await s.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
      )).values;
      final rejected = await s.proposals.change(
        proposalChange(
          await s.proposals.read('update'),
          action: WorkspaceProposalAction.reject,
        ),
      );
      expect(rejected.records, isEmpty);
      expect((await s.proposals.read('update')).items, isEmpty);
      expect(
        (await s.readDetail(
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
        )).values,
        before,
      );
      expect((await s.loadSummary()).proposals, 0);
    },
  );
  test(
    'correction keeps exact field identities and unrelated relations, and concurrent duplicates share one commit',
    () async {
      final d = await s.proposals.read('update'),
          before = await s.proposals.currentTarget('update');
      final review = WorkspaceProposalItemReview.fromItem(d.items.single);
      await expectLater(
        s.proposals.change(
          proposalChange(
            d,
            reviewed: [
              editedReview(
                review,
                values: {...review.values, 'host': 'not-listed.example'},
              ),
            ],
          ),
        ),
        proposalFailure('validation'),
      );
      final c = proposalChange(d);
      final first = s.proposals.change(c), second = s.proposals.change(c);
      // A receipt lookup during the inner ordinary-record save cannot report
      // confirmed absence and thereby permit a duplicate write.
      await expectLater(
        s.proposals.receipt(c.operationId),
        proposalFailure('unknown_outcome'),
      );
      final receipts = await Future.wait([first, second]);
      expect(receipts.first, same(receipts.last));
      final after = await s.readDetail(before.record.ref);
      expect(after.values['port'], '2222');
      expect(after.fieldIds, before.fieldIds);
      expect(after.relations, before.relations);
      expect(after.values['host'], before.values['host']);
      expect(after.version, before.version + 1);
      expect(
        (await s.loadRevisions(before.record.ref)).single.version,
        before.version,
      );
      expect((await s.proposals.read('update')).items, isEmpty);
    },
  );
  test(
    'version conflicts retain the original review, never rebase to new values, and may be explicitly rejected',
    () async {
      final d = await s.proposals.read('update'),
          before = await s.proposals.currentTarget('update');
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'external-change',
          expectedVersion: before.version,
          record: before.record,
          values: {'port': '2200'},
        ),
      );
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('conflict'),
      );
      final now = await s.proposals.read('update');
      expect(now.summary.status, WorkspaceProposalStatus.conflicted);
      expect(now.canConfirm, false);
      expect(now.items.single.before!.version, before.version);
      expect(now.items.single.proposed.values['port'], '2222');
      expect(
        (await s.proposals.currentTarget('update')).values['port'],
        '2200',
      );
      await expectLater(
        s.proposals.change(proposalChange(now)),
        proposalFailure('conflict'),
      );
      await s.proposals.change(
        proposalChange(now, action: WorkspaceProposalAction.reject),
      );
      expect((await s.readDetail(before.record.ref)).values['port'], '2200');
    },
  );
  test(
    'disabled template preserves the submitted definition; Owner confirms its frozen snapshot without reinterpretation',
    () async {
      final d = await s.proposals.read('import'),
          definition = d.items.first.proposed.definition;
      final catalog = await s.plugins.load();
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'disable-service',
          action: WorkspacePluginAction.disable,
          packageId: 'builtin.service',
          expectedVersion: catalog.version,
          expectedDigest: catalog.packages
              .singleWhere((p) => p.id == 'builtin.service')
              .digest,
        ),
      );
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('conflict'),
      );
      final now = await s.proposals.read('import');
      expect(
        now.items.first.proposed.templateState,
        WorkspaceTemplateState.disabled,
      );
      expect(now.items.first.proposed.definition, definition);
      final receipt = await s.proposals.change(
        proposalChange(
          now,
          reviewed: [WorkspaceProposalItemReview.fromItem(now.items.first)],
        ),
      );
      final saved = await s.readDetail(receipt.records.single.ref);
      expect(saved.definition, definition);
      expect(saved.templateState, WorkspaceTemplateState.disabled);
    },
  );
  test(
    'unknown reply retains a content-free receipt; exact saved snapshot survives edits and becomes unavailable after purge',
    () async {
      final d = await s.proposals.read('import'),
          c = proposalChange(
            d,
            reviewed: [WorkspaceProposalItemReview.fromItem(d.items.first)],
          );
      s.loseNextProposalReply = true;
      await expectLater(
        s.proposals.change(c),
        proposalFailure('unknown_outcome'),
      );
      final receipt = (await s.proposals.receipt(c.operationId))!,
          ref = receipt.records.single.ref;
      final original = await s.readDetail(ref);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'later-edit',
          expectedVersion: original.version,
          record: original.record,
          values: {'url': 'https://changed.example'},
        ),
      );
      expect(
        (await s.proposals.snapshot('import', ref)).detail.values,
        original.values,
      );
      final current = await s.readDetail(ref),
          deletion = await s.changeRecord(
            WorkspaceRecordChange(
              operationId: 'delete-result',
              ref: ref,
              expectedVersion: current.version,
              action: WorkspaceRecordAction.recycle,
            ),
          );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-result',
          ref: ref,
          expectedVersion: deletion.version,
          entryId: deletion.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      expect((await s.proposals.read('import')).targets.single.exists, false);
      expect(
        (await s.proposals.read('import')).targets.single.snapshotAvailable,
        false,
      );
      await expectLater(
        s.proposals.snapshot('import', ref),
        proposalFailure('history_unavailable'),
      );
      expect(await s.proposals.change(c), same(receipt));
      await expectLater(s.readDetail(ref), proposalFailure('not_found'));
      s.reset();
      expect(await s.proposals.receipt(c.operationId), isNull);
      await expectLater(s.proposals.change(c), proposalFailure('conflict'));
    },
  );
  test(
    'empty materialization does not revive proposals while reset restores the shared baseline',
    () async {
      await s.loadSummary();
      s.setScenario(SampleWorkspaceScenario.empty);
      expect(
        (await s.proposals.query(const WorkspaceProposalQuery())).total,
        0,
      );
      final created = await s.createRecord(
        WorkspaceCreate(
          operationId: 'empty-create',
          typeId: 'server',
          name: '空库新增',
          values: {'host': 'empty.example'},
        ),
      );
      expect(created, isA<WorkspaceSaved>());
      expect((await s.loadSummary()).proposals, 0);
      expect(
        (await s.proposals.query(const WorkspaceProposalQuery())).total,
        0,
      );
      s.reset();
      expect(
        (await s.proposals.query(const WorkspaceProposalQuery())).pending,
        2,
      );
    },
  );
  test(
    'proposal relation candidates use the submitted snapshot even after disabling its plugin, then expire with the pending review',
    () async {
      final d = await s.proposals.read('import');
      final view = s.proposals.relations(
        'import',
        d.items.first.id,
        d.summary.version,
      );
      final catalog = await s.plugins.load();
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'disable-snapshot',
          action: WorkspacePluginAction.disable,
          packageId: 'builtin.service',
          expectedVersion: catalog.version,
          expectedDigest: catalog.packages
              .singleWhere((p) => p.id == 'builtin.service')
              .digest,
        ),
      );
      final candidates = await view.queryRelationCandidates(
        const WorkspaceRelationQuery(
          typeId: 'service',
          key: 'hostedOn',
          keyword: '日本',
        ),
      );
      expect(
        candidates.items.single.ref,
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
      );
      expect(candidates.items.every((r) => r.type.id == 'server'), true);
      await s.proposals.change(
        proposalChange(
          await s.proposals.read('import'),
          action: WorkspaceProposalAction.reject,
        ),
      );
      await expectLater(
        view.queryRelationCandidates(
          const WorkspaceRelationQuery(typeId: 'service', key: 'hostedOn'),
        ),
        proposalFailure('conflict'),
      );
    },
  );
  test(
    'purging a pending modification target removes old Owner values from its review instead of retaining a full-body copy',
    () async {
      final initial = await s.proposals.read('update');
      final current = await s.proposals.currentTarget('update');
      expect(
        initial.items.single.before!.values['port'],
        current.values['port'],
      );
      final deleted = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'pending-recycle',
          ref: current.record.ref,
          expectedVersion: current.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      expect(
        (await s.proposals.read('update')).items.single.before!.values['port'],
        current.values['port'],
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'pending-purge',
          ref: current.record.ref,
          expectedVersion: deleted.version,
          entryId: deleted.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      final after = await s.proposals.read('update');
      expect(after.items.single.before!.values, isEmpty);
      expect(after.items.single.proposed.values.keys, ['port']);
      expect(after.items.single.changes.single.before, isNull);
      expect(after.canConfirm, false);
    },
  );
}
