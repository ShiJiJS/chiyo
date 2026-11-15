import 'package:flutter/material.dart';
import '../ui_palette.dart';
import 'approval_presentation.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

/// The Agent's explanation is separate from the facts of the actual request.
class RequestHeading extends StatelessWidget {
  const RequestHeading({
    super.key,
    required this.title,
    required this.summary,
    required this.agent,
    required this.chat,
    required this.time,
    required this.status,
  });
  final String title, summary, agent, chat, time;
  final Widget status;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Agent 提供的说明', style: libraryText(context, 12, color: c.muted)),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(title, style: libraryHeading(context, 24))),
            const SizedBox(width: 16),
            status,
          ],
        ),
        if (summary.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            summary,
            style: libraryText(context, 14, color: c.muted, height: 1.75),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (agent.isNotEmpty)
              Text(agent, style: libraryText(context, 12, color: c.muted)),
            Text(time, style: libraryText(context, 12, color: c.muted)),
            if (chat.isNotEmpty)
              ApprovalExactDetails(title: '聊天来源', text: chat),
          ],
        ),
      ],
    );
  }
}

class RequestFact {
  const RequestFact(this.label, this.value, [this.detail = '']);
  final String label, value, detail;
}

/// Reused in program/SSH approvals and their history; no inference from scripts.
class RequestFacts extends StatelessWidget {
  const RequestFacts({super.key, required this.facts});
  final List<RequestFact> facts;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    Widget cell(RequestFact fact) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(fact.label, style: libraryText(context, 12, color: c.muted)),
        const SizedBox(height: 7),
        SelectableText(
          fact.value,
          style: libraryText(context, 14, weight: FontWeight.w600, height: 1.6),
        ),
        if (fact.detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          SelectableText(
            fact.detail,
            style: libraryText(context, 12, color: c.muted, height: 1.65),
          ),
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: c.line),
          bottom: BorderSide(color: c.line),
        ),
      ),
      child:
          MediaQuery.sizeOf(context).width < 1200 ||
              MediaQuery.textScalerOf(context).scale(14) > 21
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, fact) in facts.indexed) ...[
                  if (index > 0) const SizedBox(height: 16),
                  cell(fact),
                ],
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, fact) in facts.indexed)
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.only(
                        left: index == 0 ? 0 : 20,
                        right: index == facts.length - 1 ? 0 : 20,
                      ),
                      decoration: BoxDecoration(
                        border: index == facts.length - 1
                            ? null
                            : Border(right: BorderSide(color: c.line)),
                      ),
                      child: cell(fact),
                    ),
                  ),
              ],
            ),
    );
  }
}

class SshRequestFacts extends StatelessWidget {
  const SshRequestFacts({super.key, required this.detail});
  final WorkspaceApprovalDetail detail;
  @override
  Widget build(BuildContext context) {
    final target = detail.sshTarget!;
    return RequestFacts(
      facts: [
        RequestFact(
          '连接到的服务器',
          target.host,
          '登录账号 ${target.user} · 端口 ${target.port}',
        ),
        RequestFact(
          '使用哪份凭据',
          detail.scopes
              .where((s) => s.kind == WorkspaceApprovalScopeKind.credential)
              .map((s) => s.recordName)
              .toSet()
              .join('、'),
          detail.scopes
              .where((s) => s.kind == WorkspaceApprovalScopeKind.credential)
              .map((s) => '第 ${s.recordVersion} 版')
              .toSet()
              .join('、'),
        ),
        RequestFact(
          '使用方式',
          target.credentialUse == 'sudo' ? 'sudo 认证' : 'SSH 登录',
          target.authentication == 'publickey' ? '私钥交给连接程序' : '密码交给连接程序',
        ),
      ],
    );
  }
}

class CredentialGrantBoundary extends StatelessWidget {
  const CredentialGrantBoundary({super.key, required this.detail});
  final WorkspaceApprovalDetail detail;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), ssh = detail.sshSession;
    final program =
        detail.programPlan != null ||
        detail.credential != null &&
            !{
              WorkspaceCredentialDelivery.focus,
              WorkspaceCredentialDelivery.reveal,
              WorkspaceCredentialDelivery.storage,
            }.contains(detail.credential!.delivery);
    final title = ssh
        ? detail.sshTarget?.credentialUse == 'sudo'
              ? '允许在此服务器账号进行 sudo 认证'
              : '允许登录此服务器账号并连续执行命令'
        : program
        ? '允许此程序通过指定位置使用所选凭据'
        : '允许在指定目标使用所选凭据';
    final text = ssh
        ? '限本次聊天、原设备和指定服务器账号；操作受服务器账号权限约束，不限于 Agent 说明的任务。sudo 密码需另行申请，已有免密码权限仍可使用。撤销后禁止新命令和输入，当前命令结束后断开。'
        : program
        ? '限本次聊天、原设备、所选凭据版本和接收位置。许可内可更换脚本、参数和工作目录，概要不构成只读限制。'
        : '限本次聊天、原设备和批准的填写目标。目标失效后不能改绑到新的输入框。';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.selected.withValues(alpha: .35),
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_outlined, size: 19, color: c.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: libraryText(context, 13, weight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  text,
                  style: libraryText(context, 12, color: c.muted, height: 1.75),
                ),
                if (detail.request.state == WorkspaceApprovalState.pending)
                  Text(
                    '批准后仍由 Agent 发起${ssh
                        ? '连接或认证'
                        : program
                        ? '执行'
                        : '填写'}，不会因点击批准而自动运行。',
                    style: libraryText(
                      context,
                      12,
                      color: c.muted,
                      height: 1.75,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
