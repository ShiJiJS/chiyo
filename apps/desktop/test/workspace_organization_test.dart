import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'workspace_proposals_test.dart'
    show proposalChange, editedReview, proposalFailure;

void main() {
  late SampleWorkspaceSource s;
  setUp(() => s = SampleWorkspaceSource());
  tearDown(() => s.dispose());
  const refs = [
    WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko'),
    WorkspaceRecordRef(WorkspaceRecordKind.information, 'vikunja'),
    WorkspaceRecordRef(WorkspaceRecordKind.information, 'sparky'),
  ];
  Future<List<WorkspaceDetail>> records() =>
      Future.wait(refs.map(s.readDetail));

  test(
    'concurrent fixture commands share one organization operation and reset cancels a late preparation',
    () async {
      final before = await records();
      await Future.wait([
        s.demonstrateOrganization(),
        s.demonstrateOrganization(),
      ]);
      expect(
        (await records()).map((x) => x.version),
        before.map((x) => x.version + 1),
      );
      expect(
        (await s.grantHistory.read('request:organize')).summary.operationCount,
        1,
      );
      await s.replaceFixture(sampleWorkspaceJson);
      s.setScenario(SampleWorkspaceScenario.waiting);
      final pending = expectLater(
        s.demonstrateOrganization(),
        proposalFailure('cancelled'),
      );
      await s.replaceFixture(sampleWorkspaceJson);
      await pending;
      await expectLater(
        s.proposals.read('organized'),
        proposalFailure('not_found'),
      );
      expect(
        (await records()).map((x) => x.version),
        before.map((x) => x.version),
      );
    },
  );

  test(
    'automatic organization applies only classification in the shared source, retains field identities and ends the original grant',
    () async {
      final before = await records(),
          pending = (await s.loadSummary()).proposals;
      await s.demonstrateOrganization();
      final d = await s.proposals.read('organized'), org = d.organization!;
      expect(d.items, isEmpty);
      expect(d.canConfirm, false);
      expect(d.summary.pending, false);
      expect(org.outcome, WorkspaceOrganizationOutcome.applied);
      expect(org.members, hasLength(3));
      expect(org.members.last.changed, false);
      final after = await records();
      for (var i = 0; i < before.length; i++) {
        expect(after[i].values, before[i].values);
        expect(after[i].fieldIds, before[i].fieldIds);
        expect(after[i].relations, before[i].relations);
        expect(after[i].definition, before[i].definition);
        expect(after[i].version, before[i].version + 1);
        expect(org.members[i].resultVersion, after[i].version);
        final historical = await s.previewRevision(
          refs[i],
          before[i].version,
          expectedVersion: after[i].version,
        );
        expect(historical.archive.detail.relations, before[i].relations);
        expect(historical.archive.detail.fieldIds, before[i].fieldIds);
      }
      expect(
        after.first.record.tags.map((t) => t.name),
        containsAll(['生产环境', '公网入口']),
      );
      expect((await s.loadSummary()).proposals, pending);
      final approval = await s.approvals.read('organize');
      expect(approval.request.state, WorkspaceApprovalState.completed);
      final h = await s.grantHistory.read(org.historyId!);
      expect(h.summary.state, WorkspaceGrantState.completed);
      expect(h.scopes.every((x) => !x.active), true);
      expect(h.events.single.proposalId, 'organized');
      expect(h.events.single.id, org.operationId);
      expect(h.summary.operationCount, 1);
      expect(h.canRevoke, false);
      final metadata = jsonEncode(org.toJson());
      expect(
        metadata,
        isNot(contains(before.first.values.values.first.toString())),
      );
      expect(metadata, isNot(contains('fieldIds')));
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('conflict'),
      );
      await s.demonstrateOrganization();
      expect(
        (await records()).map((x) => x.version),
        after.map((x) => x.version),
      );
    },
  );

  for (final outcome in [
    WorkspaceOrganizationOutcome.conflicted,
    WorkspaceOrganizationOutcome.failed,
    WorkspaceOrganizationOutcome.revoked,
    WorkspaceOrganizationOutcome.expired,
    WorkspaceOrganizationOutcome.sessionEnded,
  ]) {
    test(
      '${outcome.name} result is read only and no member classification is partially applied',
      () async {
        final before = await records();
        await s.demonstrateOrganization(outcome: outcome);
        final d = await s.proposals.read('organized');
        expect(d.organization!.outcome, outcome);
        expect(d.canConfirm, false);
        expect(d.summary.pending, false);
        final after = await records();
        for (var i = 0; i < before.length; i++) {
          expect(after[i].record.directoryId, before[i].record.directoryId);
          expect(
            after[i].record.tags.map((x) => x.id),
            before[i].record.tags.map((x) => x.id),
          );
          if (outcome != WorkspaceOrganizationOutcome.conflicted || i != 0) {
            expect(after[i].version, before[i].version);
            expect(after[i].values, before[i].values);
          }
        }
        final h = await s.grantHistory.read('request:organize');
        expect(h.events.single.result, outcome.label);
        expect(
          h.scopes.every((x) => !x.active),
          outcome != WorkspaceOrganizationOutcome.failed,
        );
        if (outcome == WorkspaceOrganizationOutcome.failed) {
          expect(h.summary.state, WorkspaceGrantState.active);
        }
      },
    );
  }

  test(
    'unknown automatic result never repeats a write; later original metadata observation resolves it',
    () async {
      final before = await records();
      await s.demonstrateOrganization(
        outcome: WorkspaceOrganizationOutcome.unknown,
      );
      final unknown = await s.proposals.read('organized');
      expect(
        unknown.organization!.outcome,
        WorkspaceOrganizationOutcome.unknown,
      );
      final operation = unknown.organization!.operationId;
      expect(
        unknown.organization!.members.every((m) => m.resultVersion == null),
        true,
      );
      for (var i = 0; i < 3; i++) {
        expect(
          (await s.proposals.read('organized')).organization!.outcome,
          WorkspaceOrganizationOutcome.unknown,
        );
      }
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version + 1),
      );
      s.publishOrganizationObservation();
      final observed = await s.proposals.read('organized');
      expect(
        observed.organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect(observed.organization!.operationId, operation);
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version + 1),
      );
      expect(
        (await s.grantHistory.read('request:organize')).summary.operationCount,
        1,
      );
    },
  );

  test(
    'legacy plan remains unapplied until explicit whole-plan confirmation, then retains only metadata and exact receipts',
    () async {
      final before = await records();
      await s.demonstrateLegacyOrganization();
      final d = await s.proposals.read('legacy-organize');
      expect(d.canConfirm, true);
      expect(d.organization!.legacyReview, true);
      expect(
        d.items.every(
          (i) =>
              i.proposed.values.isEmpty &&
              i.before!.values.isEmpty &&
              i.proposed.fieldIds.isEmpty &&
              i.before!.fieldIds.isEmpty,
        ),
        true,
      );
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version),
      );
      final c = proposalChange(d), r = await s.proposals.change(c);
      expect(WorkspaceProposalExpectation(d).check(c, r), same(r));
      expect(r.records, hasLength(3));
      expect(await s.proposals.change(c), same(r));
      final handled = await s.proposals.read('legacy-organize');
      expect(handled.items, isEmpty);
      expect(
        handled.organization!.outcome,
        WorkspaceOrganizationOutcome.applied,
      );
      expect(handled.organization!.legacyReview, true);
      expect(handled.targets, hasLength(3));
      final after = await records();
      for (var i = 0; i < before.length; i++) {
        expect(after[i].values, before[i].values);
        expect(after[i].fieldIds, before[i].fieldIds);
        expect(after[i].relations, before[i].relations);
      }
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version + 1),
      );
      expect(
        (await s.proposals.snapshot(
          'legacy-organize',
          refs.first,
        )).detail.version,
        r.records.first.version,
      );
    },
  );

  test(
    'legacy partial selection and injected values or renamed metadata are rejected before any mutation',
    () async {
      final before = await records();
      await s.demonstrateLegacyOrganization();
      final d = await s.proposals.read('legacy-organize');
      final reviews = d.items
          .map(WorkspaceProposalItemReview.fromItem)
          .toList();
      for (final reviewed in [
        reviews.take(1).toList(),
        [
          editedReview(
            reviews.first,
            values: {'url': 'https://outside.example'},
          ),
          ...reviews.skip(1),
        ],
        [editedReview(reviews.first, name: 'new meaning'), ...reviews.skip(1)],
      ]) {
        await expectLater(
          s.proposals.change(proposalChange(d, reviewed: reviewed)),
          proposalFailure('validation'),
        );
      }
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version),
      );
      final declined = await s.proposals.change(
        proposalChange(d, action: WorkspaceProposalAction.reject),
      );
      expect(declined.records, isEmpty);
      expect(
        (await s.proposals.read('legacy-organize')).organization!.outcome,
        WorkspaceOrganizationOutcome.rejected,
      );
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version),
      );
    },
  );

  test(
    'legacy checks the entire fixed scope, keeps conflict input and cannot overwrite a concurrent edit',
    () async {
      await s.demonstrateLegacyOrganization();
      final d = await s.proposals.read('legacy-organize'),
          before = await records();
      final last = before.last;
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'owner-change',
          record: last.record,
          expectedVersion: last.version,
          values: {...last.values, 'purpose': '主人已修改'},
        ),
      );
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('conflict'),
      );
      final current = await s.proposals.read('legacy-organize');
      expect(current.summary.status, WorkspaceProposalStatus.conflicted);
      expect(current.canConfirm, false);
      expect(
        current.items.map(
          (i) => i.proposed.record.tags.map((t) => t.id).toList(),
        ),
        d.items.map((i) => i.proposed.record.tags.map((t) => t.id).toList()),
      );
      expect((await s.readDetail(refs.first)).version, before.first.version);
      await s.proposals.change(
        proposalChange(current, action: WorkspaceProposalAction.reject),
      );
      expect((await s.readDetail(refs.last)).values['purpose'], '主人已修改');
    },
  );

  test(
    'legacy definite failure is atomic and an unknown receipt clears the controller without replay',
    () async {
      await s.demonstrateLegacyOrganization();
      final before = await records(),
          d = await s.proposals.read('legacy-organize');
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '无法保存');
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('disk_full'),
      );
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version),
      );
      final m = ProposalsController(s.proposals, s.changes);
      addTearDown(m.dispose);
      await m.open('legacy-organize');
      expect(m.canConfirm, true);
      expect(m.canEdit, false);
      s.loseNextProposalReply = true;
      await m.decide(WorkspaceProposalAction.confirm);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.uncertain, false);
      expect(m.draft, isNull);
      expect(m.detail!.items, isEmpty);
      expect(
        (await records()).map((d) => d.version),
        before.map((d) => d.version + 1),
      );
    },
  );

  test(
    'deleted targets retain original classification identities; reset removes reports and linked operation facts',
    () async {
      await s.demonstrateOrganization();
      final before = (await s.proposals.read('organized')).organization!,
          d = await s.readDetail(refs.first);
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle-org-target',
          ref: refs.first,
          expectedVersion: d.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      final after = (await s.proposals.read('organized')).organization!;
      expect(after.members.first.exists, false);
      expect(after.members.first.name, before.members.first.name);
      expect(after.members.first.record, refs.first);
      expect(after.toJson(), before.toJson());
      await s.replaceFixture(sampleWorkspaceJson);
      await expectLater(
        s.proposals.read('organized'),
        proposalFailure('not_found'),
      );
      expect(
        (await s.grantHistory.query(
          const WorkspaceGrantQuery(),
        )).items.where((h) => h.requestId == 'organize'),
        isEmpty,
      );
    },
  );
}
