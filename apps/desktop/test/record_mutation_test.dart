import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/record_mutation.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const ref = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const intent = WorkspaceOperationIntent(
  kind: WorkspaceOperationKind.edit,
  ref: ref,
  typeId: 'server',
  expectedVersion: 1,
);

class MismatchedReceiptSource extends SampleWorkspaceSource {
  WorkspaceOperationReceipt? wrongReceipt;
  @override
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(String id) async =>
      wrongReceipt;
}

void main() {
  test(
    'lost committed edit reply queries a content-free fact, never rewrites',
    () async {
      final s = SampleWorkspaceSource();
      final mutation = RecordMutation(s);
      addTearDown(s.dispose);
      addTearDown(mutation.dispose);
      final before = await s.readDetail(ref);
      var writes = 0;
      s.loseNextRecordReply = true;
      Future<WorkspaceRecordReceipt> write(String id) async {
        writes++;
        final result = await s.saveRecord(
          WorkspaceEdit(
            operationId: id,
            expectedVersion: 1,
            record: before.record,
            values: {'host': 'new.example'},
          ),
        );
        return switch (result) {
          WorkspaceSaved(:final detail) => WorkspaceRecordReceipt(
            ref: ref,
            version: detail.version,
          ),
          WorkspaceRejected(:final failure) => throw failure,
        };
      }

      await mutation.submit(intent, write);
      expect(mutation.uncertain, isTrue);
      expect((await s.readDetail(ref)).version, 2);
      s.setScenario(SampleWorkspaceScenario.failure);
      expect(await mutation.reconcile(), isNull);
      mutation.edited();
      mutation.acceptCurrentVersion();
      expect(await mutation.submit(intent, write), isNull);
      expect(mutation.frozen, isTrue);
      expect(writes, 1);
      s.setScenario(SampleWorkspaceScenario.ready);
      final fact = await mutation.reconcile();
      expect(fact!.version, 2);
      expect(fact.ref, ref);
      expect(writes, 1);
      expect(await s.loadRevisions(ref), hasLength(1));
    },
  );

  test(
    'confirmed absence preserves draft eligibility and gives explicit retry a random new ID',
    () async {
      final s = SampleWorkspaceSource();
      final mutation = RecordMutation(s);
      addTearDown(s.dispose);
      addTearDown(mutation.dispose);
      final before = await s.readDetail(ref), ids = <String>[];
      Future<WorkspaceRecordReceipt> write(String id) async {
        ids.add(id);
        final result = await s.saveRecord(
          WorkspaceEdit(
            operationId: id,
            expectedVersion: 1,
            record: before.record,
            values: {'host': 'retry.example'},
          ),
        );
        return switch (result) {
          WorkspaceSaved(:final detail) => WorkspaceRecordReceipt(
            ref: ref,
            version: detail.version,
          ),
          WorkspaceRejected(:final failure) => throw failure,
        };
      }

      s.nextSaveFailure = const WorkspaceFailure('unknown_outcome', '未知');
      await mutation.submit(intent, write);
      expect(await mutation.reconcile(), isNull);
      expect(mutation.canSubmit, isTrue);
      expect(ids, hasLength(1));
      expect((await s.readDetail(ref)).version, 1);
      expect(await mutation.submit(intent, write), isNotNull);
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(2));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^workspace-[0-9a-f]{32}$')));
      }
    },
  );

  test(
    'wrong operation, action, scope or result cannot thaw an uncertain intent',
    () async {
      final s = MismatchedReceiptSource();
      final mutation = RecordMutation(s);
      addTearDown(s.dispose);
      addTearDown(mutation.dispose);
      late String id;
      await mutation.submit(intent, (operation) async {
        id = operation;
        throw const WorkspaceFailure('unknown_outcome', '未知');
      });
      for (final wrong in [
        WorkspaceOperationReceipt(
          operationId: 'wrong',
          intent: intent,
          result: WorkspaceRecordReceipt(ref: ref, version: 2),
        ),
        WorkspaceOperationReceipt(
          operationId: id,
          intent: const WorkspaceOperationIntent(
            kind: WorkspaceOperationKind.recycle,
            ref: ref,
            expectedVersion: 1,
          ),
          result: WorkspaceRecordReceipt(ref: ref, version: 2),
        ),
        WorkspaceOperationReceipt(
          operationId: id,
          intent: const WorkspaceOperationIntent(
            kind: WorkspaceOperationKind.edit,
            ref: ref,
            typeId: 'server',
            expectedVersion: 2,
          ),
          result: WorkspaceRecordReceipt(ref: ref, version: 3),
        ),
        WorkspaceOperationReceipt(
          operationId: id,
          intent: intent,
          result: WorkspaceRecordReceipt(
            ref: const WorkspaceRecordRef(
              WorkspaceRecordKind.credential,
              'azure',
            ),
            version: 2,
          ),
        ),
        WorkspaceOperationReceipt(
          operationId: id,
          intent: intent,
          result: WorkspaceRecordReceipt(ref: ref, version: 1),
        ),
      ]) {
        s.wrongReceipt = wrong;
        expect(await mutation.reconcile(), isNull);
        expect(mutation.uncertain, isTrue);
        expect(mutation.canSubmit, isFalse);
      }
    },
  );

  test(
    'create and all lifecycle receipts survive purge without body replay or cross-command reuse',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final created =
          await s.createRecord(
                WorkspaceCreate(
                  operationId: 'create',
                  typeId: 'generic',
                  name: 'fictional',
                  description: '',
                  values: {'body': 'synthetic body'},
                ),
              )
              as WorkspaceSaved;
      final target = created.detail.record.ref;
      final edited =
          await s.saveRecord(
                WorkspaceEdit(
                  operationId: 'edit',
                  expectedVersion: 1,
                  record: created.detail.record,
                  values: {'body': 'synthetic replacement'},
                ),
              )
              as WorkspaceSaved;
      final catalog = await s.loadCatalog();
      final restored = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'revision',
          ref: target,
          expectedVersion: edited.detail.version,
          expectedCatalogVersion: catalog.version,
          action: WorkspaceRecordAction.restoreRevision,
          revisionVersion: 1,
        ),
      );
      final recycled = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle',
          ref: target,
          expectedVersion: restored.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      final revived = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore',
          ref: target,
          expectedVersion: recycled.version,
          expectedCatalogVersion: catalog.version,
          entryId: recycled.entryId,
          action: WorkspaceRecordAction.restoreRecycled,
        ),
      );
      final second = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle2',
          ref: target,
          expectedVersion: revived.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      final purge = WorkspaceRecordChange(
        operationId: 'purge',
        ref: target,
        expectedVersion: second.version,
        entryId: second.entryId,
        action: WorkspaceRecordAction.purge,
      );
      s.loseNextRecordReply = true;
      await expectLater(
        s.changeRecord(purge),
        throwsA(isA<WorkspaceFailure>()),
      );
      for (final id in [
        'create',
        'edit',
        'revision',
        'recycle',
        'restore',
        'purge',
      ]) {
        final fact = await s.recordOperationReceipt(id);
        expect(fact, isNotNull);
        expect(fact!.result.ref, target);
        expect(fact.operationId, id);
      }
      expect(
        (await s.recordOperationReceipt('create'))!.intent.kind,
        WorkspaceOperationKind.create,
      );
      expect(
        (await s.recordOperationReceipt('purge'))!.intent.entryId,
        second.entryId,
      );
      expect(
        (await s.recordOperationReceipt('purge'))!.result.entryId,
        second.entryId,
      );
      expect((await s.changeRecord(purge)).ref, target);
      await expectLater(s.readDetail(target), throwsA(isA<WorkspaceFailure>()));
      final replay = await s.createRecord(
        WorkspaceCreate(
          operationId: 'create',
          typeId: 'generic',
          name: 'fictional',
          description: '',
          values: {'body': 'synthetic body'},
        ),
      );
      expect((replay as WorkspaceRejected).failure.code, 'purged');
      final collision = await s.createRecord(
        WorkspaceCreate(
          operationId: 'purge',
          typeId: 'generic',
          name: 'collision',
          description: '',
          values: {},
        ),
      );
      expect(
        (collision as WorkspaceRejected).failure.code,
        'operation_conflict',
      );
      await expectLater(
        s.changeRecord(
          WorkspaceRecordChange(
            operationId: 'edit',
            ref: target,
            expectedVersion: 99,
            action: WorkspaceRecordAction.recycle,
          ),
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(await s.recordOperationReceipt('absent'), isNull);
      s.setScenario(SampleWorkspaceScenario.failure);
      await expectLater(
        s.recordOperationReceipt('absent'),
        throwsA(isA<WorkspaceFailure>()),
      );
      s.setScenario(SampleWorkspaceScenario.ready);
      s.reset();
      expect(await s.recordOperationReceipt('create'), isNull);
    },
  );
  test(
    'empty-library commit loss and recycle expiry keep facts without keeping the old body',
    () async {
      var now = DateTime.utc(2026, 10, 27);
      final s = SampleWorkspaceSource(now: () => now);
      addTearDown(s.dispose);
      await s.loadCatalog();
      s.setScenario(SampleWorkspaceScenario.empty);
      final draft = WorkspaceCreate(
        operationId: 'empty-create',
        typeId: 'generic',
        name: 'empty-library test',
        description: '',
        values: {'body': 'synthetic'},
      );
      s.loseNextRecordReply = true;
      await expectLater(
        s.createRecord(draft),
        throwsA(isA<WorkspaceFailure>()),
      );
      final fact = (await s.recordOperationReceipt('empty-create'))!;
      expect((await s.loadSummary()).records, 1);
      final recycle = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'expire-recycle',
          ref: fact.result.ref,
          expectedVersion: 1,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      now = now.add(const Duration(days: 31));
      expect((await s.queryRecycled()).total, 0);
      expect(await s.recordOperationReceipt('empty-create'), isNotNull);
      expect(await s.recordOperationReceipt('expire-recycle'), isNotNull);
      await expectLater(
        s.readRecycled(recycle.entryId!),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(
        (await s.createRecord(draft) as WorkspaceRejected).failure.code,
        'purged',
      );
      expect((await s.loadSummary()).records, 0);
    },
  );
}
