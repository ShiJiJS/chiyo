import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/sample_workspace_hosts.dart';
import 'workspace_proposals_test.dart'
    show proposalChange, proposalFailure, editedReview;

void main() {
  late SampleWorkspaceSource s;
  setUp(() => s = SampleWorkspaceSource());
  tearDown(() => s.dispose());
  Future<WorkspaceProposalDetail> draft(String id) async {
    await s.demonstrateFieldProposals();
    return s.proposals.read(id);
  }

  Future<WorkspaceRecordReceipt> commit(String id) async =>
      (await s.proposals.change(
        proposalChange(await draft(id)),
      )).records.single;
  test(
    'four scalar intents keep the exact template snapshot, preserve corrections and unrelated links, allocate new identities and recycle only removed scope',
    () async {
      final d = await draft('fields-server'),
          before = await s.proposals.currentTarget(d.summary.id),
          receipt = await s.proposals.change(proposalChange(d));
      final current = await s.readDetail(before.record.ref);
      expect(current.definition, before.definition);
      expect(current.fieldIds['port'], before.fieldIds['port']);
      expect(current.values['port'], '2222');
      expect(current.fieldIds['user'], isNot(before.fieldIds['user']));
      expect(current.values['user'], 'ops@beichen.example');
      expect(current.values.containsKey('purpose'), false);
      expect(current.fieldIds.containsKey('purpose'), false);
      expect(workspaceFields(current).any((f) => f['key'] == 'purpose'), false);
      expect(
        workspaceFields(
          current,
        ).singleWhere((f) => f['key'] == 'user')['label'],
        '运维联系标识',
      );
      expect(current.fieldIds['recoveryContact'], isNotNull);
      expect(current.relations, before.relations);
      final archived = await s.readRecycled(receipt.records.single.entryId!);
      expect(archived.wholeItem, false);
      expect(archived.detail.values.keys.toSet(), {'user', 'purpose'});
      expect(archived.detail.fieldIds['user'], before.fieldIds['user']);
      expect(archived.detail.values.containsKey('host'), false);
    },
  );
  test(
    'a field-delete proposal leaves the record present; explicit partial restore gets new identity and requires the observed current version',
    () async {
      final d = await draft('delete-field'),
          old = await s.proposals.currentTarget(d.summary.id),
          r = (await s.proposals.change(proposalChange(d))).records.single;
      expect(d.summary.wholeDeletion, false);
      expect(d.summary.kind, WorkspaceProposalKind.deletion);
      final now = await s.readDetail(old.record.ref);
      expect(now.values.containsKey('auth'), false);
      expect(now.values['url'], old.values['url']);
      final terminal = await s.proposals.read(d.summary.id);
      expect(terminal.targets.single.exists, true);
      expect(terminal.targets.single.version, old.version);
      await expectLater(
        s.changeRecord(
          WorkspaceRecordChange(
            operationId: 'no-current-observation',
            ref: old.record.ref,
            expectedVersion: r.version,
            entryId: r.entryId,
            action: WorkspaceRecordAction.restoreRecycled,
          ),
        ),
        proposalFailure('conflict'),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'explicit-restore',
          ref: old.record.ref,
          expectedVersion: r.version,
          expectedCurrentVersion: now.version,
          expectedCatalogVersion: (await s.loadCatalog()).version,
          entryId: r.entryId,
          action: WorkspaceRecordAction.restoreRecycled,
        ),
      );
      final restored = await s.readDetail(old.record.ref);
      expect(restored.values['auth'], old.values['auth']);
      expect(restored.fieldIds['auth'], isNot(old.fieldIds['auth']));
      expect(restored.fieldIds['url'], old.fieldIds['url']);
    },
  );
  test(
    'restoring replaced scalar fields preserves the current meaning and restores the former meaning as an independent retained field',
    () async {
      final d = await draft('fields-server'),
          old = await s.proposals.currentTarget(d.summary.id),
          r = await commit(d.summary.id),
          now = await s.readDetail(old.record.ref);
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-collisions',
          ref: old.record.ref,
          expectedVersion: r.version,
          expectedCurrentVersion: now.version,
          expectedCatalogVersion: (await s.loadCatalog()).version,
          entryId: r.entryId,
          action: WorkspaceRecordAction.restoreRecycled,
        ),
      );
      final restored = await s.readDetail(old.record.ref);
      expect(restored.values['user'], now.values['user']);
      expect(restored.fieldIds['user'], now.fieldIds['user']);
      final former =
          restored.retainedFields.singleWhere(
                (f) => f['originKey'] == 'user',
              )['key']
              as String;
      expect(restored.values[former], old.values['user']);
      expect(restored.fieldIds[former], isNot(old.fieldIds['user']));
      expect(restored.values['purpose'], old.values['purpose']);
      expect(restored.fieldIds['port'], old.fieldIds['port']);
    },
  );
  test(
    'entry mutations are independent leaves; new entries and replacement leaves never reuse approved identities',
    () async {
      final d = await draft('fields-profile'),
          old = await s.proposals.currentTarget(d.summary.id),
          previous = WorkspaceRepeatedEntry.read(old.values['education']);
      final r = await commit(d.summary.id),
          current = await s.readDetail(old.record.ref),
          entries = WorkspaceRepeatedEntry.read(current.values['education']);
      expect(entries.first.id, previous.first.id);
      expect(entries.first.fieldIds['title'], previous.first.fieldIds['title']);
      expect(
        entries.first.fieldIds['detail'],
        isNot(previous.first.fieldIds['detail']),
      );
      expect(entries.first.fieldIds.containsKey('period'), false);
      expect(entries.first.period, '');
      expect(entries.first.label('detail'), '研究成果');
      expect(entries.length, previous.length + 1);
      final oldIds = previous
          .expand((e) => [e.id, ...e.fieldIds.values])
          .toSet();
      expect(
        oldIds.intersection({entries.last.id, ...entries.last.fieldIds.values}),
        isEmpty,
      );
      final removed = await s.readRecycled(r.entryId!);
      final fragment = WorkspaceRepeatedEntry.read(
        removed.detail.values['education'],
      ).single;
      expect(fragment.fieldIds.keys.toSet(), {'period', 'detail'});
      expect(fragment.title, '');
      expect(current.values['experience'], old.values['experience']);
      final oldRevision = await s.previewRevision(
        old.record.ref,
        old.version,
        expectedVersion: current.version,
      );
      expect(oldRevision.canRestore, false);
      expect(oldRevision.missingFields, isNotEmpty);
      await expectLater(
        s.changeRecord(
          WorkspaceRecordChange(
            operationId: 'do-not-resurrect-removed-leaf',
            ref: old.record.ref,
            expectedVersion: current.version,
            expectedCatalogVersion: (await s.loadCatalog()).version,
            revisionVersion: old.version,
            action: WorkspaceRecordAction.restoreRevision,
          ),
        ),
        proposalFailure('recycle_restore_required'),
      );

      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-leaf-collision',
          ref: old.record.ref,
          expectedVersion: r.version,
          expectedCurrentVersion: current.version,
          expectedCatalogVersion: (await s.loadCatalog()).version,
          entryId: r.entryId,
          action: WorkspaceRecordAction.restoreRecycled,
        ),
      );
      final after = WorkspaceRepeatedEntry.read(
        (await s.readDetail(old.record.ref)).values['education'],
      );
      expect(after.first.fieldIds, entries.first.fieldIds);
      expect(after.last.id, isNot(previous.first.id));
      expect(after.last.detail, previous.first.detail);
      expect(
        after.last.fieldIds['detail'],
        isNot(previous.first.fieldIds['detail']),
      );
    },
  );
  test(
    'invalid reviewed delta or write failure changes neither the target, retained revisions nor recycle entries',
    () async {
      final d = await draft('fields-server'),
          old = await s.proposals.currentTarget(d.summary.id),
          review = WorkspaceProposalItemReview.fromItem(d.items.single);
      final recycledBefore = (await s.queryRecycled()).items
          .map((e) => e.id)
          .toList();
      final values = {...review.values, 'host': 'must-not-write'};
      await expectLater(
        s.proposals.change(
          proposalChange(d, reviewed: [editedReview(review, values: values)]),
        ),
        proposalFailure('validation'),
      );
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '无法写入');
      await expectLater(
        s.proposals.change(proposalChange(d)),
        proposalFailure('disk_full'),
      );
      expect((await s.readDetail(old.record.ref)).values, old.values);
      expect(await s.loadRevisions(old.record.ref), isEmpty);
      expect(
        (await s.queryRecycled()).items.map((e) => e.id).toList(),
        recycledBefore,
      );
      expect((await s.proposals.read(d.summary.id)).summary.pending, true);
    },
  );
  test(
    'purging a partial entry erases old snapshots and observations while preserving live values and credential relations',
    () async {
      final d = await draft('fields-server'),
          r = await commit(d.summary.id),
          live = await s.readDetail(r.ref);
      expect((await s.loadRevisions(r.ref)), isNotEmpty);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'keep-newer-revision',
          expectedVersion: live.version,
          record: live.record,
          values: {'port': '2233'},
        ),
      );
      final retainedCurrent = await s.readDetail(r.ref);

      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-partial',
          ref: r.ref,
          expectedVersion: r.version,
          entryId: r.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      final after = await s.readDetail(r.ref);
      expect(after.values, retainedCurrent.values);
      expect(after.fieldIds, live.fieldIds);
      expect(after.relations, live.relations);
      expect(after.version, retainedCurrent.version);
      expect((await s.loadRevisions(r.ref)).map((v) => v.version).toList(), [
        live.version,
      ]);
      expect(
        (await s.proposals.read('update')).items.single.before!.values,
        isEmpty,
      );
    },
  );
  test(
    'a whole purge removes all partial recycle fragments belonging to the same record',
    () async {
      final r = await commit('fields-server'),
          current = await s.readDetail(r.ref);
      final all = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'whole-after-field',
          ref: r.ref,
          expectedVersion: current.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'whole-after-field-purge',
          ref: r.ref,
          expectedVersion: all.version,
          entryId: all.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      expect(
        (await s.queryRecycled()).items.where((e) => e.record.ref == r.ref),
        isEmpty,
      );
      await expectLater(
        s.readRecycled(r.entryId!),
        proposalFailure('not_found'),
      );
    },
  );
  test(
    'changing the meaning of a built-in host slot cannot silently reuse it as a connection endpoint',
    () async {
      await s.loadCatalog();
      final old = await s.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun'),
      );
      var current = old;
      final plugin = (await s.plugins.load()).packages.firstWhere(
        (p) => p.id == 'builtin.server',
      );
      final hosts = SampleWorkspaceHosts(
        readable: () async {},
        beforeWrite: () {},
        changed: () {},
        records: () => [current],
        plugin: () => plugin,
        pluginVersion: () => 1,
        empty: () => false,
      );
      final target = WorkspaceHostTarget.record(old.record.ref);
      expect((await hosts.read(target)).endpoint, isNotNull);
      current = WorkspaceDetail(
        record: old.record,
        version: old.version + 1,
        definition: old.definition,
        fieldIds: old.fieldIds,
        values: old.values,
        fieldOverrides: {
          'host': {'key': 'host', 'label': '归档地址', 'type': 'text'},
        },
      );
      expect((await hosts.read(target)).endpoint, isNull);
    },
  );
}
