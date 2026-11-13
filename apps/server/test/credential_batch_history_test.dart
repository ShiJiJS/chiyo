import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'credential_batch_routes_test.dart'
    show target, noPrivate, base, ownerBase;
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'owner history, per-item revoke and unknown acknowledgement survive HTTPS and reopen without replay',
    () async {
      var now = DateTime.utc(2026, 11, 14);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(f.dispose);
      final a = f.agents.first;
      final session = (await a.call('/session/lifecycle', {
        'chatLabel': 'Synthetic history chat',
      }))['sessionSecret'];
      final cs = await f.runtime.run(() async {
        final owner = f.runtime.service.owner;
        final values = <ManagedCredential>[];
        for (var i = 0; i < 2; i++) {
          final c = await owner.createStringCredential(
            name: 'Synthetic history credential $i',
            publicPurpose: '',
            secret: 'NEVER-HISTORY-MATERIAL',
          );
          values.add(
            await owner.updateCredentialMetadata(
              c.id,
              c.revision,
              name: c.name,
              publicPurpose: '',
              privateNote: '',
              suggestedBinding: 'password',
              discoverable: true,
            ),
          );
        }
        return values;
      });
      final id =
          (await a.call('$base/request', {
                'sessionSecret': session,
                'operationId': 'history-submit',
                'input': {
                  'protocolVersion': 3,
                  'purpose': 'Synthetic history workflow',
                  'agentName': 'History Agent',
                  'externalChatId': 'history-public-chat',
                  'submissionVersion': 1,
                  'items': [
                    for (final (index, c) in cs.indexed)
                      {
                        'credentialId': c.id,
                        'destination': target('p${index + 1}'),
                      },
                  ],
                },
              }))['requestId']
              as String;
      Future<WorkspaceApprovalDetail> detail() async => approvalDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
        ),
      );
      Future<void> decide(
        String op,
        WorkspaceApprovalAction action,
        List<String> items,
      ) async {
        final change = WorkspaceApprovalChange(
          operationId: op,
          requestId: id,
          reviewToken: (await detail()).reviewToken,
          action: action,
          selected: items,
        );
        final receipt = approvalReceiptFromJson(
          await f.owner.request(
            'POST',
            '/v1/owner/approvals/decisions',
            approvalChangeToJson(change),
          ),
        );
        expect(receipt.matches(change), true);
      }

      await decide('history-approve', WorkspaceApprovalAction.approve, [
        'b1',
        'b2',
      ]);
      final begun = await a.call('$base/begin', {
        'sessionSecret': session,
        'requestId': id,
        'operationId': 'history-use',
        'itemIds': ['b2'],
      });
      expect(begun['privateProof'], isA<String>());
      final checking = (await detail()).batchOperations.single;
      expect(checking.state, 'checking');
      now = now.add(const Duration(seconds: 31));
      final operationPath =
          '$ownerBase/${Uri.encodeComponent(id)}/operations/history-use';
      final raw = await f.owner.request('GET', operationPath);
      noPrivate(raw);
      expect(jsonEncode(raw), isNot(contains('NEVER-HISTORY-MATERIAL')));
      final unknown = WorkspaceCredentialBatchOperation.fromJson(raw);
      expect(unknown.state, 'unknown');
      expect(
        unknown.revision,
        checking.revision,
        reason: 'Elapsed time is an observation, not a committed revision.',
      );
      expect(unknown.updates(checking), true);
      expect(unknown.needsAttention, true);
      final historyId = 'request:$id';
      Future<WorkspaceGrantDetail> history() async => grantDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/grant-history/entries/${Uri.encodeComponent(historyId)}',
        ),
      );
      final h = await history();
      expect(h.summary.state, WorkspaceGrantState.active);
      expect(h.summary.operationCount, 1);
      expect(h.summary.agentClaim, 'History Agent');
      expect(h.scopes.every((s) => s.active && s.materialVersion == 1), true);
      expect(h.targets.every((t) => !t.snapshotAvailable), true);
      expect(h.events.any((e) => e.result.contains('填写结果未知')), true);
      expect(h.scopeNotice, contains('需要核对'));
      final listed = grantResultsFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/grant-history/query',
          grantQueryToJson(
            const WorkspaceGrantQuery(keyword: 'history credential 1'),
          ),
        ),
      );
      expect(listed.items.single.id, historyId);
      final wire = approvalDetailToJson(await detail(), version: 3);
      expect(
        approvalDetailFromJson(
          Map<String, dynamic>.from(wire),
        ).batchOperations.single.state,
        'unknown',
      );
      final corrupt = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
      ((corrupt['batchOperations'] as List).single as Map)['requestId'] =
          'another-request';
      expect(() => approvalDetailFromJson(corrupt), throwsFormatException);

      await decide('history-revoke-a', WorkspaceApprovalAction.revoke, ['b1']);
      expect((await detail()).approved, {'b2'});
      expect((await history()).summary.state, WorkspaceGrantState.partial);
      expect((await history()).scopes.where((s) => s.active).single.id, 'b2');
      expect(
        (await a.call('$base/begin', {
          'sessionSecret': session,
          'requestId': id,
          'operationId': 'blocked-new',
          'itemIds': ['b2'],
        }))['errorCode'],
        'fill_needs_attention',
      );
      final acknowledgement = {
        'operationId': 'history-owner-checked',
        'revision': unknown.revision,
      };
      final acknowledged = WorkspaceCredentialBatchOperation.fromJson(
        await f.owner.request(
          'POST',
          '$operationPath/acknowledge',
          acknowledgement,
        ),
      );
      expect(acknowledged.updates(unknown), true);
      expect(acknowledged.state, 'unknown');
      expect(acknowledged.needsAttention, false);
      expect(acknowledged.itemResults, isEmpty);
      expect(acknowledged.finishedAt, null);
      final before = await f.runtime.run(
        () async => f.runtime.service.owner.credentialBatchOperations.length,
      );
      await f.reopen();
      final repeated = WorkspaceCredentialBatchOperation.fromJson(
        await f.owner.request(
          'POST',
          '$operationPath/acknowledge',
          acknowledgement,
        ),
      );
      expect(repeated.toJson(), acknowledged.toJson());
      expect(
        (await history()).events.any((e) => e.description == '用户已核对原操作与目标'),
        true,
      );
      final after = await detail();
      expect(after.batchOperations.single.attentionAcknowledgedAt, now);
      expect(
        await f.runtime.run(
          () async => f.runtime.service.owner.credentialBatchOperations.length,
        ),
        before,
        reason:
            'Review, query, acknowledgement and reopen never start another operation.',
      );
      for (final public in [
        grantDetailToJson(await history()),
        approvalDetailToJson(after, version: 3),
      ]) {
        noPrivate(public);
        expect(jsonEncode(public), isNot(contains('NEVER-HISTORY-MATERIAL')));
      }
    },
  );
}
