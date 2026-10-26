import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/credential_mutation.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  test(
    'lost reply queries the committed operation; failed reconciliation never permits a second write',
    () async {
      final source = SampleWorkspaceSource();
      final mutation = CredentialMutation(source.credentials);
      addTearDown(source.dispose);
      addTearDown(mutation.dispose);
      var writes = 0;
      await mutation.submit((id) async {
        writes++;
        await source.credentials.save(
          WorkspaceCredentialWrite(
            operationId: id,
            name: '丢失回执的测试凭据',
            candidateId: 'string-env',
          ),
        );
        throw const WorkspaceFailure('unknown_outcome', '回执未到达');
      });
      expect(mutation.uncertain, isTrue);
      expect((await source.loadSummary()).records, 32);
      source.setScenario(SampleWorkspaceScenario.failure);
      expect(await mutation.reconcile(), isNull);
      expect(mutation.uncertain, isTrue);
      await mutation.submit((id) async {
        writes++;
        throw StateError('must not replay');
      });
      expect(writes, 1);
      source.setScenario(SampleWorkspaceScenario.ready);
      final receipt = await mutation.reconcile();
      expect(receipt, isNotNull);
      expect(mutation.uncertain, isFalse);
      expect(
        (await source.credentials.read(receipt!.ref)).record.name,
        '丢失回执的测试凭据',
      );
      expect((await source.loadSummary()).records, 32);
      expect(writes, 1);
    },
  );
  test(
    'confirmed absence permits one explicit retry with a new operation identity',
    () async {
      final source = SampleWorkspaceSource();
      final mutation = CredentialMutation(source.credentials);
      addTearDown(source.dispose);
      addTearDown(mutation.dispose);
      final operations = <String>[];
      Future<WorkspaceCredentialReceipt> write(String id) {
        operations.add(id);
        return source.credentials.save(
          WorkspaceCredentialWrite(
            operationId: id,
            name: '明确重试的凭据',
            candidateId: 'string-env',
          ),
        );
      }

      source.nextSaveFailure = const WorkspaceFailure(
        'unknown_outcome',
        '结果未知',
      );
      await mutation.submit(write);
      expect(mutation.uncertain, isTrue);
      expect(await mutation.reconcile(), isNull);
      expect(mutation.canSubmit, isTrue);
      expect(operations, hasLength(1));
      final receipt = await mutation.submit(write);
      expect(receipt, isNotNull);
      expect(operations, hasLength(2));
      expect(operations[0], isNot(operations[1]));
      expect((await source.loadSummary()).records, 32);
    },
  );
}
