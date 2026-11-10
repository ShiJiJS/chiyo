import 'dart:convert';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'CLI provenance persists through real approval, proposal decisions and server restart without sharing grants by name',
    () async {
      var now = DateTime.utc(2026, 11, 11);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      final cli = AgentClient.remote(
        f.profiles.first,
        requireSubmissionMetadata: true,
        sourceAgent: '合成维护 Agent',
        externalChatId: 'synthetic-chat-124',
      );
      final other = AgentClient.remote(
        f.profiles.first,
        requireSubmissionMetadata: true,
        sourceAgent: '合成维护 Agent',
        externalChatId: 'synthetic-chat-124',
      );
      addTearDown(() async {
        cli.close();
        other.close();
        await f.dispose();
      });
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation('合成服务器', '', [
          const FieldInput('主机', '', 'synthetic.invalid'),
        ]),
      );
      expect((await cli.openLifecycleSession('合成维护聊天'))['status'], 'ok');
      expect((await other.openLifecycleSession('合成维护聊天'))['status'], 'ok');
      final fields = [FieldRef(item.id, item.fields.single.id).toJson()];
      final missing = await cli.execute({
        'command': 'import-submit',
        'items': [],
      });
      expect(missing['errorCode'], 'invalid_submission_metadata');
      expect(missing['fieldErrors'], contains('title'));
      expect(f.repo.importProposals, isEmpty);
      final request = await cli.execute({
        'command': 'request',
        'purpose': '核对合成主机地址',
        'operationId': 'source-read-once',
        'fields': fields,
      });
      expect(request['status'], 'pending');
      final id = request['requestId'] as String;
      var decisionNumber = 0;
      Future<WorkspaceApprovalDetail> read(String id) async =>
          approvalDetailFromJson(
            await f.owner.request('GET', '/v1/owner/approvals/$id'),
          );
      Future<void> approve(String id) async {
        final detail = await read(id);
        expect(detail.request.agentClaim, '合成维护 Agent');
        expect(detail.request.chatClaim, contains('synthetic-chat-124'));
        await f.owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'synthetic-approve-${++decisionNumber}',
              requestId: id,
              reviewToken: detail.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: detail.scopes
                  .where((s) => s.available)
                  .map((s) => s.id),
            ),
          ),
        );
      }

      await approve(id);
      expect(
        (await cli.execute({'command': 'claim', 'requestId': id}))['status'],
        'ok',
      );
      expect(
        (await other.execute({'command': 'claim', 'requestId': id}))['status'],
        'unauthorized',
      );
      Future<WorkspaceGrantSummary> history(String requestId) async =>
          grantResultsFromJson(
            await f.owner.request(
              'POST',
              '/v1/owner/grant-history/query',
              grantQueryToJson(const WorkspaceGrantQuery()),
            ),
          ).items.singleWhere((h) => h.requestId == requestId);
      expect((await history(id)).agentClaim, '合成维护 Agent');
      await f.reopen();
      expect((await read(id)).request.agentClaim, '合成维护 Agent');
      expect((await history(id)).chatClaim, contains('synthetic-chat-124'));
      expect(
        (await cli.execute({
          'command': 'request',
          'purpose': '核对合成主机地址',
          'operationId': 'source-read-once',
          'fields': fields,
        }))['requestId'],
        id,
      );
      expect(
        (await cli.execute({
          'command': 'request',
          'purpose': '核对合成主机地址',
          'operationId': 'source-read-once',
          'agentName': '另一名 Agent',
          'fields': fields,
        }))['status'],
        'operation_conflict',
      );
      Future<WorkspaceProposalDetail> proposal(String id) async =>
          proposalDetailFromJson(
            await f.owner.request('GET', '/v1/owner/proposals/$id'),
          );
      Future<void> confirm(String id) async {
        final d = await proposal(id);
        expect(d.summary.agentClaim, '合成维护 Agent');
        expect(d.summary.chatClaim, contains('synthetic-chat-124'));
        await f.owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(
            WorkspaceProposalChange(
              operationId: 'synthetic-save-${++decisionNumber}',
              proposalId: id,
              version: d.summary.version,
              reviewToken: d.reviewToken,
              action: WorkspaceProposalAction.confirm,
              reviewed: d.items.map(WorkspaceProposalItemReview.fromItem),
            ),
          ),
        );
      }

      final added = await cli.execute({
        'command': 'import-submit',
        'title': '新增 NAS 应用信息',
        'purpose': '补齐合成应用清单',
        'items': [
          {
            'name': '合成应用',
            'fields': [
              {'name': '用途', 'value': '自动验收'},
            ],
          },
        ],
      });
      expect(added['status'], 'pending');
      final addId = added['proposalId'] as String;
      expect((await proposal(addId)).summary.title, '新增 NAS 应用信息');
      await confirm(addId);
      final updated = await cli.execute({
        'command': 'update-submit',
        'title': '更新服务器用途',
        'purpose': '修改合成资料',
        'update': {
          'itemId': item.id,
          'baseVersion': item.version,
          'description': '合成用途',
          'changes': [],
        },
      });
      expect(updated['status'], 'pending');
      final updateId = updated['proposalId'] as String;
      expect((await proposal(updateId)).summary.title, '更新服务器用途');
      await confirm(updateId);
      final organization = await cli.execute({
        'command': 'organize-request',
        'title': '核对服务器分类',
        'purpose': '检查合成分类',
        'itemIds': [item.id],
      });
      expect(organization['status'], 'pending');
      final taskId = organization['taskId'] as String;
      await approve(taskId);
      final organized = await cli.execute({
        'command': 'organize-submit',
        'taskId': taskId,
        'changes': [],
      });
      expect(organized['status'], 'confirmed');
      expect((await proposal(taskId)).summary.title, '核对服务器分类');
      expect((await history(taskId)).title, '核对服务器分类');
      final current = f.repo.items.singleWhere((i) => i.id == item.id);
      final deleted = await cli.execute({
        'command': 'delete-submit',
        'title': '移除已停用合成服务器',
        'purpose': '移除合成资料',
        'itemId': item.id,
        'baseVersion': current.version,
      });
      expect(deleted['status'], 'pending');
      final deleteId = deleted['proposalId'] as String;
      expect(
        (await other.execute({
          'command': 'delete-status',
          'proposalId': deleteId,
        }))['status'],
        'unauthorized',
      );
      await confirm(deleteId);
      now = now.add(const Duration(minutes: 1));
      await f.reopen();
      for (final entry in {
        addId: '新增 NAS 应用信息',
        updateId: '更新服务器用途',
        taskId: '核对服务器分类',
        deleteId: '移除已停用合成服务器',
      }.entries) {
        final d = await proposal(entry.key);
        expect(d.summary.title, entry.value);
        expect(d.summary.agentClaim, '合成维护 Agent');
        expect(d.summary.chatClaim, contains('synthetic-chat-124'));
        expect(d.summary.pending, false);
      }
      expect(
        jsonEncode(await cli.execute({'command': 'session-check'})),
        isNot(contains(cli.sessionSecret!)),
      );
    },
  );
}
