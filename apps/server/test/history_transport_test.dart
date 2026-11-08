import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

void main() {
  const ref = WorkspaceRecordRef(WorkspaceRecordKind.information, 'synthetic');
  WorkspaceGrantSummary summary(String id) => WorkspaceGrantSummary(
    id: id,
    title: 'Synthetic metadata',
    kind: WorkspaceApprovalKind.credential,
    state: WorkspaceGrantState.unavailable,
    agentClaim: 'Synthetic',
    chatClaim: 'Synthetic',
    purpose: 'Synthetic',
    recordedAt: DateTime.utc(2026, 11, 9),
    operationCount: 1,
  );
  test(
    'history preserves legacy zero versions and an off-page kept selection',
    () {
      final detail = WorkspaceGrantDetail(
        summary: summary('one'),
        scopes: [
          const WorkspaceGrantedScope(
            id: 'field',
            record: ref,
            label: 'Body',
            recordVersion: 0,
            kind: WorkspaceApprovalScopeKind.field,
            active: false,
          ),
        ],
        targets: [
          const WorkspaceGrantTarget(
            record: ref,
            name: 'Synthetic',
            version: 0,
            exists: false,
            snapshotAvailable: false,
          ),
        ],
      );
      final restored = grantDetailFromJson(grantDetailToJson(detail));
      expect(restored.scopes.single.recordVersion, 0);
      expect(restored.targets.single.version, 0);
      final query = WorkspaceGrantResults(
        items: [summary('one')],
        total: 2,
        offset: 0,
        selection: 'two',
        selectionIndex: 1,
      );
      expect(grantResultsFromJson(grantResultsToJson(query)).selection, 'two');
      final injected = grantDetailToJson(detail)
        ..['materialBytes'] = 'SYNTHETIC_NOT_METADATA';
      expect(() => grantDetailFromJson(injected), throwsFormatException);
      final nested = grantDetailToJson(detail);
      (nested['scopes'] as List).single['password'] = 'SYNTHETIC_NOT_METADATA';
      expect(() => grantDetailFromJson(nested), throwsFormatException);
    },
  );
  test(
    'lifecycle and batch changes reject extra fields, unknown versions and ambiguous scopes',
    () {
      const c = WorkspaceRecordChange(
        operationId: 'original',
        ref: ref,
        expectedVersion: 1,
        action: WorkspaceRecordAction.recycle,
      );
      final valid = recordChangeToJson(c);
      expect(recordChangeFromJson(valid).expectedVersion, 1);
      expect(
        () => recordChangeFromJson({...valid, 'bytes': 'SYNTHETIC'}),
        throwsFormatException,
      );
      expect(
        () => recordChangeFromJson({...valid, 'wireVersion': 2}),
        throwsFormatException,
      );
      expect(
        () => recordChangeFromJson({...valid, 'expectedVersion': 0}),
        throwsFormatException,
      );
      final batch = WorkspaceLibraryRecycleCommand(
        operationId: 'batch',
        reviewToken: 'a' * 64,
        selection: WorkspaceLibrarySelection(records: [ref]),
      );
      final json = batchChangeToJson(batch);
      expect(batchChangeFromJson(json).inputHash, batch.inputHash);
      expect(
        () => batchChangeFromJson({...json, 'batchId': 'different-batch'}),
        throwsFormatException,
      );
      expect(
        () => batchChangeFromJson({...json, 'reviewToken': 'not-a-review'}),
        throwsFormatException,
      );
      expect(
        () => batchChangeFromJson({
          ...json,
          'options': {
            'names': {'unknown': 'Name'},
            'parents': {},
          },
        }),
        throwsFormatException,
      );
      final receipt = WorkspaceOperationReceipt(
        operationId: c.operationId,
        intent: WorkspaceOperationIntent.change(c),
        result: WorkspaceRecordReceipt(ref: ref, version: 2),
      );
      final wire = lifecycleReceiptToJson(receipt);
      expect(
        lifecycleReceiptFromJson(wire).intent.matches(receipt.intent),
        true,
      );
      expect(
        () => lifecycleReceiptFromJson({...wire, 'operationId': 'another'}),
        throwsFormatException,
      );
    },
  );
}
