@TestOn('!windows')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/mac_pending_menu.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';

import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';

void main() {
  test(
    'menu projects real queues, checks exact approvals and reconciles a lost reply',
    () async {
      var now = DateTime.now().toUtc();
      final fixture = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(fixture.dispose);
      final proxy = await OwnerReplyProxy.start(
        tls: fixture.tls,
        trust: fixture.trust,
        target: () => fixture.owner.address,
        serverId: fixture.owner.serverId,
      );
      addTearDown(proxy.close);
      final source = RemoteWorkspaceSource(
        await OwnerClient.connect(
          address: proxy.address,
          token: fixture.token,
          trust: fixture.trust,
        ),
      );
      addTearDown(source.dispose);
      final item = await fixture.runtime.run(
        () => fixture.runtime.service.owner.createInformation('合成资料', '', [
          const FieldInput('主机地址', '', 'SYNTHETIC_PRIVATE_VALUE'),
          const FieldInput('登录账号', '', 'SYNTHETIC_UNREQUESTED'),
        ]),
      );
      final session = fixture.runtime.service.agent.openSession('合成菜单聊天');
      final proposal = await fixture.runtime.run(
        () => fixture.runtime.service.agent.submitImport(
          session,
          [
            ImportItemInput('合成提案内容', '', [
              const FieldInput('正文', '', 'SYNTHETIC_PROPOSAL_BODY'),
            ]),
          ],
          title: '合成提案标题',
          agentName: '菜单测试 Agent',
          purpose: '整理合成资料',
        ),
      );
      Future<String> request(String purpose) async =>
          (await fixture.runtime.run(
            () => fixture.runtime.service.agent.request(
              session,
              purpose,
              [FieldRef(item.id, item.fields.first.id)],
              agentName: '菜单测试 Agent',
              externalChatId: 'menu-test-chat',
            ),
          )).id;

      final approved = await request('核对主机地址');
      final published = <Map<String, Object?>>[];
      final opened = <(WorkspacePage, String?)>[];
      var theme = WorkspaceTheme.light;
      var canAct = true;
      final menu = MacPendingMenu(
        publish: (state) async => published.add(state),
        open: (page, id) async => opened.add((page, id)),
        canAct: () => canAct,
        theme: () => theme,
        clock: () => now,
      );
      addTearDown(() async {
        menu.dispose();
        await menu.idle;
      });
      menu.bind(source, location: '合成服务器');
      await menu.idle;
      Map<String, Object?> latest() => published.last;
      Map<String, Object?> row(String id) =>
          (latest()['requests'] as List<Map<String, Object?>>).singleWhere(
            (row) => row['id'] == id,
          );
      Object? presentation() => latest()['presentation'];
      const decisions = 'POST /v1/owner/approvals/decisions';
      Future<void> decide(String id, bool approve, {Object? view}) =>
          menu.handle('pendingMenuDecision', {
            'presentation': view ?? presentation(),
            'id': id,
            'approve': approve,
          });
      expect(latest()['approvalCount'], 1);
      expect(latest()['proposalCount'], 1);
      expect(row(approved)['scope'], '合成资料 · 主机地址');
      expect(row(approved)['agent'], '菜单测试 Agent');
      expect(row(approved)['purpose'], '核对主机地址');
      expect(row(approved)['duration'], '授权时长 · 2 小时');
      expect(row(approved)['quick'], true);
      final display = jsonEncode(latest());
      expect(display, contains('合成提案标题'));
      expect(display, isNot(contains('SYNTHETIC_')));
      await menu.handle('pendingMenuOpen', {
        'presentation': presentation(),
        'category': 'proposals',
        'id': proposal,
      });
      expect(opened.single, (WorkspacePage.proposals, proposal));

      final view = presentation();
      canAct = false;
      await decide(approved, true);
      expect(proxy.requests[decisions], isNull);
      canAct = true;
      await Future.wait([decide(approved, true), decide(approved, true)]);
      final grant = await source.approvals.read(approved);
      expect(grant.request.state, WorkspaceApprovalState.approved);
      expect(
        grant.fieldExpiresAt!.difference(grant.decidedAt!),
        const Duration(hours: 2),
      );
      expect(grant.approved, hasLength(1));
      expect(latest()['approvalCount'], 0);
      await decide(approved, true, view: view);
      expect(proxy.requests[decisions], 1);

      final denied = await request('拒绝这条申请');
      await menu.refresh();
      await decide(denied, false);
      expect(
        (await source.approvals.read(denied)).request.state,
        WorkspaceApprovalState.denied,
      );

      final lost = await request('响应丢失后核对');
      await menu.refresh();
      proxy.dropNextPath = '/v1/owner/approvals/decisions';
      await decide(lost, true);
      expect(
        (await source.approvals.read(lost)).request.state,
        WorkspaceApprovalState.approved,
      );
      expect(latest()['checkResult'], true);
      expect(latest()['notice'], '结果尚未确认，请核对。');
      final posts = proxy.requests[decisions];
      await decide(lost, true);
      await menu.handle('pendingMenuCheck', {'presentation': presentation()});
      expect(proxy.requests[decisions], posts);
      expect(latest()['checkResult'], false);
      expect(latest()['notice'], '已记录本次决定。');

      await source.approvals.change(
        WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: approved,
          reviewToken: (await source.approvals.read(approved)).reviewToken,
          action: WorkspaceApprovalAction.revoke,
        ),
      );
      await menu.refresh();
      expect(latest()['approvalCount'], 0);
      expect(
        (await source.approvals.read(approved)).request.state,
        WorkspaceApprovalState.revoked,
      );

      final expired = await request('处理前已到期');
      await menu.refresh();
      now = now.add(const Duration(hours: 2, seconds: 1));
      final beforeExpired = proxy.requests[decisions];
      await decide(expired, true);
      expect(proxy.requests[decisions], beforeExpired);
      expect(latest()['approvalCount'], 0);
      expect(
        (await source.approvals.read(expired)).request.state,
        WorkspaceApprovalState.expired,
      );

      theme = WorkspaceTheme.dark;
      await menu.refresh();
      expect(latest()['dark'], true);
      menu.setOffline(true);
      await menu.idle;
      expect(latest()['location'], '连接已断开');
      expect(latest()['approvalCount'], isNull);
      expect(latest()['requests'], isEmpty);
      menu.setOffline(false);
      await menu.idle;
      final stale = presentation();
      final second = await DeviceCredentialFixture.create();
      addTearDown(second.dispose);
      final other = RemoteWorkspaceSource(
        await OwnerClient.connect(
          address: second.owner.address,
          token: second.token,
          trust: second.trust,
        ),
      );
      addTearDown(other.dispose);
      menu.bind(other, location: '另一资料库');
      await menu.idle;
      expect(latest()['location'], '另一资料库');
      expect(latest()['approvalCount'], 0);
      expect(latest()['proposalCount'], 0);
      expect(latest()['proposals'], isEmpty);
      await menu.handle('pendingMenuOpen', {
        'presentation': stale,
        'category': 'proposals',
        'id': proposal,
      });
      expect(opened, hasLength(1));
      expect((await source.proposals.read(proposal)).summary.pending, true);
      expect(fixture.runtime.service.owner.information, hasLength(1));
    },
  );
}
