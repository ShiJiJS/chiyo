import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_proposals_test.dart'
    show proposalChange, proposalFailure, editedReview;

void main() {
  late SampleWorkspaceSource s;
  setUp(() => s = SampleWorkspaceSource());
  tearDown(() => s.dispose());
  test(
    'whole deletion keeps one fixed scope, rejects edits, commits through the same recycle history and retains only exact metadata',
    () async {
      await s.demonstrateDeletionProposal();
      await s.demonstrateDeletionProposal();
      expect(
        (await s.proposals.query(const WorkspaceProposalQuery())).total,
        3,
      );
      final d = await s.proposals.read('delete-service');
      expect(d.canConfirm, true);
      expect(d.items.single.proposed.values, isEmpty);
      final before = d.items.single.before!;
      expect(before.values, isNotEmpty);
      final review = WorkspaceProposalItemReview.fromItem(d.items.single);
      await expectLater(
        s.proposals.change(
          proposalChange(
            d,
            reviewed: [editedReview(review, name: 'another scope')],
          ),
        ),
        proposalFailure('validation'),
      );
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '无法保存');
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('disk_full'),
      );
      expect((await s.readDetail(before.record.ref)).version, before.version);
      final c = proposalChange(d), result = await s.proposals.change(c);
      expect(result.records.single.entryId, isNotNull);
      expect(result.records.single.version, before.version + 1);
      await expectLater(
        s.readDetail(before.record.ref),
        proposalFailure('not_found'),
      );
      expect(await s.proposals.change(c), same(result));
      final terminal = await s.proposals.read(d.summary.id);
      expect(terminal.items, isEmpty);
      expect(terminal.targets.single.version, before.version);
      expect(terminal.targets.single.exists, false);
      final snapshot = await s.proposals.snapshot(
        d.summary.id,
        before.record.ref,
      );
      expect(snapshot.detail.values, before.values);
      expect(snapshot.detail.version, before.version);
      final recycled = await s.readRecycled(result.records.single.entryId!);
      expect(recycled.detail.record.ref, before.record.ref);
      expect(recycled.detail.fieldIds, before.fieldIds);
    },
  );
  test(
    'changed target cannot be deleted or silently rebased and rejection preserves the concurrent content',
    () async {
      await s.demonstrateDeletionProposal();
      final d = await s.proposals.read('delete-service'),
          target = d.items.single.before!;
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'concurrent',
          expectedVersion: target.version,
          record: target.record,
          values: {'purpose': '并发编辑仍需保留'},
        ),
      );
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('conflict'),
      );
      final conflict = await s.proposals.read(d.summary.id);
      expect(conflict.canConfirm, false);
      expect(conflict.summary.status, WorkspaceProposalStatus.conflicted);
      expect(conflict.items.single.before!.version, target.version);
      expect(
        (await s.proposals.currentTarget(d.summary.id)).values['purpose'],
        '并发编辑仍需保留',
      );
      await s.proposals.change(
        proposalChange(conflict, action: WorkspaceProposalAction.reject),
      );
      expect(
        (await s.readDetail(target.record.ref)).values['purpose'],
        '并发编辑仍需保留',
      );
      expect((await s.proposals.read(d.summary.id)).items, isEmpty);
    },
  );
  test(
    'lost deletion reply is reconciled without a second recycle; purging removes the exact old snapshot and cannot erase another object',
    () async {
      await s.demonstrateDeletionProposal();
      final d = await s.proposals.read('delete-service'),
          ref = d.items.single.before!.record.ref,
          c = proposalChange(d);
      s.loseNextProposalReply = true;
      await expectLater(
        s.proposals.change(c),
        proposalFailure('unknown_outcome'),
      );
      final receipt = (await s.proposals.receipt(c.operationId))!;
      expect(await s.proposals.change(c), same(receipt));
      final r = receipt.records.single;
      await expectLater(
        s.proposals.snapshot(
          d.summary.id,
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
        ),
        proposalFailure('unsupported'),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'delete-purge',
          ref: ref,
          expectedVersion: r.version,
          entryId: r.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      expect(
        (await s.proposals.read(d.summary.id)).targets.single.snapshotAvailable,
        false,
      );
      await expectLater(
        s.proposals.snapshot(d.summary.id, ref),
        proposalFailure('history_unavailable'),
      );
      expect(
        (await s.proposals.receipt(c.operationId))!.records.single.entryId,
        r.entryId,
      );
    },
  );
}
