import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'agents_controller.dart';
import 'library_widgets.dart';
import 'settings_page.dart' show SettingsPreferenceRow;
import 'settings_layout.dart';
import 'workspace_source.dart';

class WorkspaceAgentsPage extends StatelessWidget {
  const WorkspaceAgentsPage({
    super.key,
    required this.controller,
    required this.onRequest,
    this.onModalChanged,
  });
  final WorkspaceAgentsController controller;
  final ValueChanged<String> onRequest;
  final ValueChanged<bool>? onModalChanged;
  Future<void> _open(BuildContext context, WorkspaceAgentView view) async {
    controller.open(view);
    onModalChanged?.call(true);
    String? request;
    try {
      request = await showDesktopDialog<String>(
        context,
        builder: (_) => _AgentFlow(controller: controller, view: view),
      );
    } finally {
      controller.close();
      onModalChanged?.call(false);
    }
    if (request != null) onRequest(request);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final m = controller,
          v = m.value,
          c = UiPalette.of(context),
          large = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
      final label = v == null
          ? m.readFailure == null
                ? '正在检测…'
                : '暂不可用'
          : m.loading || m.readFailure != null
          ? '上次观察 · ${v.connection.label}'
          : v.connection.label;
      final badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: m.available && v?.connection == WorkspaceAgentConnection.ready
              ? c.successSurface
              : c.paper,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          key: const ValueKey('agents-connection'),
          style: libraryText(
            context,
            13,
            color:
                m.available && v?.connection == WorkspaceAgentConnection.ready
                ? c.success
                : c.muted,
            weight: FontWeight.w600,
          ),
        ),
      );
      return SettingsPageContent(
        scrollKey: const ValueKey('agents-page-scroll'),
        title: 'Agent 接入',
        description: '会话关联与接入状态',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 25),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 45,
                      height: 45,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.selected,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'C',
                        style: libraryText(
                          context,
                          20,
                          color: c.accent,
                          weight: FontWeight.w600,
                          height: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Codex',
                            style: libraryText(
                              context,
                              20,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '通过 Skill 与会话 hooks 接入',
                            style: libraryText(context, 13, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    if (!large) badge,
                  ],
                ),
                if (large) ...[const SizedBox(height: 14), badge],
              ],
            ),
          ),
          if (m.loading) const LinearProgressIndicator(),
          if (m.readFailure != null)
            Text(
              m.readFailure!.message,
              key: const ValueKey('agents-read-error'),
              style: libraryText(context, 14, color: c.danger, height: 1.9),
            ),
          SettingsCard(
            children: [
              SettingsPreferenceRow(
                title: '连接诊断',
                description: v == null
                    ? '正在核对本机服务、CLI、Skill 与 hooks…'
                    : '本机服务${v.serviceAvailable ? '可用' : '不可用'} · CLI ${v.cli.label} · Skill ${v.skill.label}。连接状态与资料权限分开核对。',
                control: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    DesktopButton(
                      key: const ValueKey('agents-refresh'),
                      onPressed: m.loading ? null : m.load,
                      child: const Text('重新检测'),
                    ),
                    DesktopButton(
                      key: const ValueKey('agents-diagnostics'),
                      onPressed: m.loading
                          ? null
                          : () =>
                                _open(context, WorkspaceAgentView.diagnostics),
                      child: const Text('查看诊断'),
                    ),
                  ],
                ),
              ),
              SettingsPreferenceRow(
                title: '会话关联',
                description: v == null
                    ? '所选会话关联尚未确认。'
                    : v.session.state == WorkspaceAgentSessionState.linked
                    ? '${v.session.label}（Agent 自述） · ${v.session.pendingRequests} 条待处理申请 · ${v.session.activeGrants} 项有效授权。每个聊天独立关联。'
                    : _sessionExplanation(v.session.state),
                control: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (v != null && v.sessions.isNotEmpty)
                      SizedBox(
                        width: 260,
                        child: DesktopSelect<String>(
                          key: const ValueKey('agents-session-select'),
                          value:
                              v.sessions.any((s) => s.id == m.selectedSessionId)
                              ? m.selectedSessionId
                              : '',
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('请选择会话'),
                            ),
                            for (final s in v.sessions)
                              DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  '${s.label} · ${s.id!.substring(0, s.id!.length.clamp(0, 8))} · ${s.state.label}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: m.loading
                              ? null
                              : (id) => m.selectSession(id == '' ? null : id),
                        ),
                      ),
                    DesktopButton(
                      key: const ValueKey('agents-session'),
                      onPressed: m.loading
                          ? null
                          : () => _open(context, WorkspaceAgentView.session),
                      child: const Text('查看所选会话'),
                    ),
                  ],
                ),
              ),
              SettingsPreferenceRow(
                title: '接入流程',
                description:
                    '准备接入材料、审查 Skill 与准确 hook 命令，再通过宿主正式信任入口启用。检测不会安装或信任命令。',
                control: DesktopButton(
                  key: const ValueKey('agents-setup'),
                  onPressed: () => _open(context, WorkspaceAgentView.setup),
                  child: const Text('查看接入流程'),
                ),
              ),
              SettingsPreferenceRow(
                title: 'Agent 录入约定',
                description: '先复用资料与模板；目录按保留用途，标签按查找习惯，关联必须有来源依据。',
                control: DesktopButton(
                  key: const ValueKey('agents-rules'),
                  onPressed: () => _open(context, WorkspaceAgentView.rules),
                  child: const Text('查看说明'),
                ),
              ),
              SettingsPreferenceRow(
                title: 'Mac 本机焦点填充',
                divider: false,
                description: '当前默认关闭，独立于会话接入。连接成功不代表可以向前台应用填入凭据。',
                control: Text(
                  '当前不可用',
                  style: libraryText(context, 14, color: c.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            '连接成功不会自动获得资料权限。聊天名称为 Agent 自述；聊天 ID 不能作为访问证明。私密关联由受控接入传递，本页不展示或复制。',
            style: libraryText(context, 14, color: c.muted, height: 1.9),
          ),
        ],
      );
    },
  );
}

String _sessionExplanation(WorkspaceAgentSessionState state) => switch (state) {
  WorkspaceAgentSessionState.unselected => '请选择要查看的会话；本页不会猜测你正在使用哪个聊天。',
  WorkspaceAgentSessionState.linked => '所选会话已在服务端关联；具体内容仍需独立申请，宿主信任需另外核对。',
  WorkspaceAgentSessionState.missing =>
    '所选会话尚未取得有效关联。按接入流程检查后，在正确的新聊天中接入；不要粘贴聊天 ID 或私密值来猜测关联。',
  WorkspaceAgentSessionState.mismatch =>
    '私密关联与当前聊天的绑定无法核对。停止复用该关联，在正确聊天重新检查；不能仅凭公开聊天 ID 找回访问能力。',
  WorkspaceAgentSessionState.ended =>
    '原会话已结束，旧授权不会因恢复聊天或重新检测而复活。新的工作需要新的关联与申请。',
};

class _AgentFlow extends StatefulWidget {
  const _AgentFlow({required this.controller, required this.view});
  final WorkspaceAgentsController controller;
  final WorkspaceAgentView view;
  @override
  State<_AgentFlow> createState() => _AgentFlowState();
}

class _AgentFlowState extends State<_AgentFlow> {
  WorkspaceAgentsController get m => widget.controller;
  int _page = 0;
  String? _shownSession;
  @override
  void initState() {
    super.initState();
    if ({
      WorkspaceAgentView.diagnostics,
      WorkspaceAgentView.session,
    }.contains(widget.view)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(m.readDetails());
      });
    }
  }

  Widget _text(BuildContext context, String text, {bool muted = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(
          text,
          style: libraryText(
            context,
            14,
            color: muted ? UiPalette.of(context).muted : null,
            height: 1.9,
          ),
        ),
      );
  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: libraryText(context, 18, weight: FontWeight.w600)),
  );
  List<Widget> _setup(BuildContext context) => [
    _heading(context, '1. 准备稳定目录中的接入材料'),
    _text(
      context,
      '使用交付的 CLI 准备工具，在一个新的稳定目录生成 CLI、Skill 和 hooks.json。准备材料与安装、启用、信任是分别的动作；失败不能覆盖已有配置。',
    ),
    _heading(context, '2. 审查 Skill 与三类 hook'),
    _text(
      context,
      '核对 SessionStart、SubagentStart、SessionEnd 的准确命令、事件范围和超时。通过宿主正式信任入口逐条审查；不要直接写信任摘要或绕过信任。命令或定义变化后重新核对，旧信任不能沿用。',
    ),
    _heading(context, '3. 在正确聊天建立关联'),
    _text(
      context,
      '启用后在新的聊天中取得该聊天绑定的私密关联。缺失或绑定不符时按接入流程处理，不从公开聊天 ID、父聊天 ID 或同名文件中找回读取能力。',
    ),
    _heading(context, '4. 先申请，再由你批准'),
    _text(
      context,
      'Agent 可先查公开目录，再提出所需字段、文件版本、凭据使用或分类整理申请。已连接不等于已获批准；期限固定，重复使用不续期。',
    ),
    _heading(context, '结束、恢复与子任务'),
    _text(
      context,
      '根 SessionEnd 结束对应授权会话。压缩或恢复不会自动重连或延长期限；fork 与 clear 是独立聊天。主 Agent 必须用已持有的私密证明显式委托，子 Agent 只使用绑定自己的关联；子任务完成或中断不等于根会话结束。',
      muted: true,
    ),
  ];
  List<Widget> _rules(BuildContext context) => [
    _text(context, '先查已有资料与模板，避免重复录入。模板名称不决定资料必须放在哪个目录。'),
    _text(
      context,
      '目录按保留用途选择，标签按查找习惯复用。标签名称和归属默认对接入 Agent 可见，不代表正文、文件或凭据可读，也不允许擅自改分类。',
    ),
    _text(
      context,
      '字段记录有明确含义的信息；重复经历按独立条目和字段身份处理。关联必须有来源依据，无法确认时留空，不根据名称猜测关系。',
    ),
    _text(context, '缺少模板时可准备声明式 JSON 插件包交你审查。安装模板与确认资料提案是两次不同决定，安装不批准任何资料写入。'),
    _text(
      context,
      '修改提案按提交时定义和版本审阅，冲突先核对，不用同名新对象代替旧身份。普通附件使用文件专用入口，凭据走专用入口，不能作为普通字段展开秘密。',
    ),
    _text(
      context,
      '分类整理只在获批元数据和分类范围内工作，完成后只读查看结果，不新增第二次审批或扩展为正文修改。',
      muted: true,
    ),
  ];
  List<Widget> _diagnostics(
    BuildContext context,
    WorkspaceAgentOverview report,
  ) {
    final c = UiPalette.of(context);
    return [
      _heading(context, report.connection.label),
      _text(
        context,
        '观察时间 ${libraryLocalDateTime(report.observedAt)}。本页只读取接入观察，不执行 hook、安装材料或更改信任。',
        muted: true,
      ),
      SettingsPreferenceRow(
        title: '本机服务',
        description: report.serviceReason ?? '可以接收访问申请；批准范围仍由你决定。',
        control: Text(
          report.serviceAvailable ? '可用' : '不可用',
          style: libraryText(
            context,
            14,
            color: report.serviceAvailable ? c.success : c.warning,
          ),
        ),
      ),
      SettingsPreferenceRow(
        title: '配套 CLI',
        description: '使用随包、经核对的 CLI；不通过另一个启动路径掩盖接入错误。',
        control: Text(report.cli.label, style: libraryText(context, 14)),
      ),
      SettingsPreferenceRow(
        title: '访问 Skill',
        description: '核对已审阅的访问约定和配套工具。诊断不安装或更新个人 Skill。',
        control: Text(report.skill.label, style: libraryText(context, 14)),
      ),
      for (final event in WorkspaceAgentOverview.requiredEvents) ...[
        const SizedBox(height: 18),
        _heading(context, event),
        if (report.hooks.where((h) => h.event == event).firstOrNull
            case final hook?) ...[
          _text(
            context,
            '${hook.observedState.label} · 超时 ${hook.timeoutSeconds} 秒${hook.matcher == null ? '' : ' · 匹配 ${hook.matcher}'}',
          ),
          SelectableText(
            hook.command,
            key: ValueKey('agents-hook-${hook.event}'),
            style: libraryText(
              context,
              13,
              height: 1.8,
            ).copyWith(fontFamily: 'Menlo'),
          ),
          if (!hook.verified) ...[
            const SizedBox(height: 10),
            _text(context, '此定义尚未完整核对。回到宿主正式信任入口审查准确命令；本页不替你信任。', muted: true),
          ],
        ] else
          _text(context, '无法核对该事件的宿主定义与信任状态，请在宿主接入设置中检查。'),
      ],
      const SizedBox(height: 18),
      _heading(context, '所选会话关联'),
      _text(context, _sessionExplanation(report.session.state)),
      _text(
        context,
        '接入观察、申请发起方自述和实际资料授权分别核对。Mac 焦点填充保持不可用；诊断通过也不会启用它。',
        muted: true,
      ),
    ];
  }

  void _request(String id) {
    final detail = m.session, current = m.value;
    if (!m.available ||
        detail == null ||
        current == null ||
        !detail.matches(current) ||
        !detail.requests.any((r) => r.id == id)) {
      return;
    }
    Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final c = UiPalette.of(context),
          detail = m.session,
          dynamicView = {
            WorkspaceAgentView.diagnostics,
            WorkspaceAgentView.session,
          }.contains(widget.view);
      if (_shownSession != detail?.session.id) {
        _shownSession = detail?.session.id;
        _page = 0;
      }
      final pages = (((detail?.requests.length ?? 0) + 4) ~/ 5).clamp(
            1,
            1 << 30,
          ),
          page = _page.clamp(0, pages - 1),
          error = m.detailFailure ?? m.readFailure;
      return DesktopDialog(
        width: 860,
        title: Text(switch (widget.view) {
          WorkspaceAgentView.setup => 'Agent 接入流程',
          WorkspaceAgentView.rules => 'Agent 录入与整理约定',
          WorkspaceAgentView.diagnostics => '接入诊断',
          WorkspaceAgentView.session => '所选会话关联',
        }),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (dynamicView && (m.loading || m.detailBusy))
              const LinearProgressIndicator(),
            if (widget.view == WorkspaceAgentView.setup) ..._setup(context),
            if (widget.view == WorkspaceAgentView.rules) ..._rules(context),
            if (widget.view == WorkspaceAgentView.diagnostics &&
                m.report != null)
              ..._diagnostics(context, m.report!),
            if (widget.view == WorkspaceAgentView.session &&
                detail != null) ...[
              _heading(
                context,
                detail.session.label == null
                    ? detail.session.state.label
                    : '${detail.session.label}（Agent 自述）',
              ),
              _text(context, _sessionExplanation(detail.session.state)),
              _text(
                context,
                '${detail.session.totalRequests} 条关联申请 · ${detail.session.pendingRequests} 条待处理 · ${detail.session.activeGrants} 项有效授权。私密关联不会在这里显示。',
                muted: true,
              ),
              if (detail.requests.isEmpty)
                _text(context, '当前没有可列出的关联申请。连接本身不创建申请或授权。'),
              for (final r in detail.requests.skip(page * 5).take(5))
                SettingsPreferenceRow(
                  title: r.title,
                  description:
                      '${r.state.label} · ${libraryLocalDateTime(r.submittedAt)} · ${r.purpose}（Agent 自述）',
                  control: DesktopButton(
                    key: ValueKey('agents-request-${r.id}'),
                    onPressed: m.loading || m.detailBusy
                        ? null
                        : () => _request(r.id),
                    child: const Text('查看申请'),
                  ),
                ),
            ],
            if (dynamicView && error != null)
              Text(
                error.message,
                key: const ValueKey('agents-detail-error'),
                style: libraryText(context, 14, color: c.danger, height: 1.9),
              ),
          ],
        ),
        actions: [
          if (widget.view == WorkspaceAgentView.session && pages > 1) ...[
            DesktopButton(
              key: const ValueKey('agents-session-prev'),
              onPressed: m.detailBusy || page == 0
                  ? null
                  : () => setState(() => _page = page - 1),
              child: const Text('上一页'),
            ),
            Text('${page + 1} / $pages'),
            DesktopButton(
              key: const ValueKey('agents-session-next'),
              onPressed: m.detailBusy || page + 1 >= pages
                  ? null
                  : () => setState(() => _page = page + 1),
              child: const Text('下一页'),
            ),
          ],
          if (dynamicView)
            DesktopButton(
              key: const ValueKey('agents-detail-retry'),
              onPressed: m.loading || m.detailBusy ? null : m.retryDetails,
              child: const Text('重新检测'),
            ),
          DesktopButton(
            key: const ValueKey('agents-flow-close'),
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
