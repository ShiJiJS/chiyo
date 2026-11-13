import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'a lost delete submission reply recovers the original encrypted proposal after restart and normal App approval deletes only the requested field',
    () async {
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/delete/submit',
      );
      addTearDown(f.dispose);
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation('Synthetic host', '', [
          const FieldInput('Obsolete', '', 'PRIVATE-OBSOLETE-SYNTHETIC'),
          const FieldInput('Keep', '', 'PRIVATE-RETAIN-SYNTHETIC'),
        ]),
      );
      final opened = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic deletion trial',
      });
      final session = opened['sessionSecret'] as String;
      final context = File('${f.root.path}/delete-chat/context.json');
      await ChiyoContext(
        chatId: 'delete-recovery-trial',
        agentName: 'Trial Agent',
        secret: session,
        port: f.profiles.first.address.port,
        connection: f.profiles.first,
      ).saveNew(context);
      final business = File('${f.root.path}/delete.json');
      final input = {
        'title': 'Delete synthetic field',
        'purpose': 'Remove unused synthetic value',
        'itemId': item.id,
        'baseVersion': item.version,
        'fieldId': item.fields.first.id,
      };
      await business.writeAsString(jsonEncode(input));
      Future<ChiyoRunResult> call(List<String> args) => ChiyoCli(
        environment: {'CHIYO_CONTEXT': context.path},
      ).run([...args, '--json']);
      final check = await call([
        'proposals',
        'check',
        '--kind',
        'delete',
        '--input',
        business.path,
      ]);
      expect(check.exitCode, 0, reason: check.render());
      expect(f.repo.deleteProposals, isEmpty);
      final submitted = await call([
        'proposals',
        'submit',
        '--kind',
        'delete',
        '--check',
        (check.output['data'] as Map)['checkId'] as String,
        '--input',
        business.path,
        '--operation',
        'delete-once',
      ]);
      expect(submitted.exitCode, 7, reason: submitted.render());
      expect((submitted.output['data'] as Map)['operationId'], 'delete-once');
      expect(f.repo.deleteProposals, hasLength(1));
      expect(f.claimPosts, 1);
      expect(f.runtime.service.owner.information.single.fields, hasLength(2));
      final proposalId = f.repo.deleteProposals.single.id;
      await business.delete(); // A saved server receipt needs no source reread.
      await f.reopen();
      final recovered = await call(['operations', 'retry', 'delete-once']);
      expect(recovered.exitCode, 0, reason: recovered.render());
      expect((recovered.output['data'] as Map)['requestId'], proposalId);
      expect(f.claimPosts, 1);
      expect(f.repo.deleteProposals, hasLength(1));
      expect(
        (await f.agents.last.call('/delete/status', {
          'sessionSecret': session,
          'operationId': 'delete-once',
        }))['status'],
        'unauthorized',
      );
      final other = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic deletion trial',
      });
      expect(
        (await f.agents.first.call('/delete/status', {
          'sessionSecret': other['sessionSecret'],
          'operationId': 'delete-once',
        }))['status'],
        'not_found',
      );
      final detail = proposalDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/proposals/${Uri.encodeComponent(proposalId)}',
        ),
      );
      expect(detail.summary.title, 'Delete synthetic field');
      final change = WorkspaceProposalChange(
        operationId: 'approve-delete-once',
        proposalId: proposalId,
        version: detail.summary.version,
        reviewToken: detail.reviewToken,
        action: WorkspaceProposalAction.confirm,
        reviewed: detail.items.map(WorkspaceProposalItemReview.fromItem),
      );
      final receipt = proposalReceiptFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(change),
        ),
      );
      expect(
        WorkspaceProposalExpectation(detail).check(change, receipt),
        same(receipt),
      );
      final retained = f.runtime.service.owner.information.single;
      expect(retained.id, item.id);
      expect(retained.fields.single.id, item.fields.last.id);
      expect(retained.fields.single.value, 'PRIVATE-RETAIN-SYNTHETIC');
      expect(
        (await f.agents.first.call('/delete/status', {
          'sessionSecret': session,
          'operationId': 'delete-once',
        }))['status'],
        'confirmed',
      );
      expect((await call(['operations', 'retry', 'delete-once'])).exitCode, 0);
      expect(f.repo.deleteProposals, hasLength(1));
      expect(f.repo.recycleEntries, hasLength(1));
      final changed = await f.agents.first.call('/delete/submit', {
        ...input,
        'baseVersion': 2,
        'sessionSecret': session,
        'operationId': 'delete-once',
        'agentName': 'Trial Agent',
        'externalChatId': 'delete-recovery-trial',
        'submissionVersion': 1,
      });
      expect(changed['status'], 'operation_conflict');
      for (final result in [check, submitted, recovered]) {
        expect(result.render(), isNot(contains('PRIVATE-')));
        expect(result.render(), isNot(contains(session)));
      }
    },
  );
}
