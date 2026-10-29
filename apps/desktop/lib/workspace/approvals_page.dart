import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'approvals_controller.dart';
import 'approval_executions.dart';
import 'workspace_source.dart';

class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({
    super.key,
    required this.controller,
    required this.onRecord,
    this.onSettings,
    this.onHistory,
    this.onRetry,
  });
  final ApprovalsController controller;
  final ValueChanged<WorkspaceRecordRef> onRecord;
  final VoidCallback? onSettings, onRetry;
  final ValueChanged<String>? onHistory;
  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  final _search = TextEditingController(),
      _list = ScrollController(),
      _detail = ScrollController();
  ApprovalsController get model => widget.controller;
  String? _selection;
  WorkspaceApprovalState? _decisionState;
  String _queryKey = '';
  @override
  void initState() {
    super.initState();
    _selection = model.selection;
    _decisionState = model.detail?.request.state;
    _search.text = model.keyword;
    model.addListener(_changed);
    _list.addListener(() {
      model.listScroll = _list.offset;
    });
    _detail.addListener(() {
      model.detailScroll = _detail.offset;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_list.hasClients) {
        _list.jumpTo(model.listScroll.clamp(0, _list.position.maxScrollExtent));
      }
      if (_detail.hasClients) {
        _detail.jumpTo(
          model.detailScroll.clamp(0, _detail.position.maxScrollExtent),
        );
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    final queryKey = '${model.keyword}/${model.filter.name}/${model.offset}';
    if (_queryKey != queryKey) {
      _queryKey = queryKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _list.hasClients) _list.jumpTo(0);
      });
    }
    final state = model.detail?.request.state;
    if (_selection != model.selection ||
        state != null && _decisionState != null && state != _decisionState) {
      _selection = model.selection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detail.hasClients) _detail.jumpTo(0);
      });
    }
    if (state != null) _decisionState = state;
    if (_search.text != model.keyword && !_search.value.composing.isValid) {
      _search.text = model.keyword;
    }
    setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _search.dispose();
    _list.dispose();
    _detail.dispose();
    super.dispose();
  }

  Widget _section(BuildContext c, String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 26),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: libraryText(c, 17, weight: FontWeight.w700)),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
  Widget _message(BuildContext c, String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: libraryText(
          c,
          13,
          color: error ? UiPalette.of(c).danger : UiPalette.of(c).muted,
        ),
      ),
    ),
  );

  Widget _scope(BuildContext context, WorkspaceApprovalScope scope) {
    final c = UiPalette.of(context),
        d = model.draft!,
        current = model.detail!,
        checked = d.selected.contains(scope.id),
        editable =
            model.canDecide &&
            current.request.state == WorkspaceApprovalState.pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          checked: checked,
          child: DesktopButton(
            key: ValueKey('approval-scope-${scope.id}'),
            kind: DesktopButtonKind.quiet,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 0),
            onPressed: editable && (scope.available || checked)
                ? () => model.toggle(scope.id)
                : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  checked ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 19,
                  color: checked ? c.accent : c.muted,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(scope.label, style: libraryText(context, 14)),
                      if (!scope.available && scope.unavailableReason != null)
                        Text(
                          scope.unavailableReason!,
                          style: libraryText(context, 12, color: c.warning),
                        ),
                      if (current.request.state ==
                          WorkspaceApprovalState.pending)
                        Text(
                          scope.requested ? '原申请范围' : '可补选字段',
                          style: libraryText(context, 12, color: c.muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (scope.kind == WorkspaceApprovalScopeKind.file && checked)
          Padding(
            padding: const EdgeInsets.only(left: 30, bottom: 16),
            child: DesktopSelect<int>(
              key: ValueKey('approval-file-${scope.id}'),
              value: d.files[scope.id],
              isExpanded: true,
              decoration: const InputDecoration(labelText: '普通附件版本'),
              items: [
                if (d.files[scope.id] != null &&
                    !scope.fileVersions.any(
                      (v) => v.ref.version == d.files[scope.id],
                    ))
                  DropdownMenuItem(
                    value: d.files[scope.id],
                    enabled: false,
                    child: const Text('原选版本已不可用'),
                  ),
                for (final v in scope.fileVersions)
                  DropdownMenuItem(
                    value: v.ref.version,
                    child: Text(
                      'v${v.ref.version} · ${v.filename} · ${v.mediaType} · ${(v.byteLength / 1024).toStringAsFixed(1)} KB',
                    ),
                  ),
              ],
              onChanged: editable && scope.available
                  ? (v) {
                      if (v != null) model.chooseFile(scope.id, v);
                    }
                  : null,
            ),
          ),
        Divider(height: 1, color: c.line),
      ],
    );
  }

  Widget _scopes(BuildContext context) {
    final grouped = <String, List<WorkspaceApprovalScope>>{};
    for (final x in model.detail!.scopes) {
      (grouped[x.section] ??= []).add(x);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in grouped.entries)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  e.key,
                  style: libraryText(
                    context,
                    13,
                    color: UiPalette.of(context).muted,
                    weight: FontWeight.w600,
                  ),
                ),
                if (e.value.every((s) => s.entryId != null)) ...[
                  DesktopButton(
                    key: ValueKey('approval-expand-${e.value.first.entryId}'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: model.frozen ? null : () => model.expand(e.key),
                    alignment: Alignment.centerLeft,
                    leading: Icon(
                      model.draft!.expanded.contains(e.key)
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                    ),
                    child: Text(
                      '${model.draft!.selected.intersection(e.value.map((x) => x.id).toSet()).length} / ${e.value.length} 个字段 · 展开核对',
                    ),
                  ),
                  if (model.draft!.expanded.contains(e.key))
                    for (final x in e.value) _scope(context, x),
                ] else
                  for (final x in e.value) _scope(context, x),
              ],
            ),
          ),
        if (grouped.isEmpty) const Text('当前没有可审批的范围。'),
      ],
    );
  }

  Future<void> _tip(BuildContext context) async {
    final r = model.detail!.request;
    final text = switch (r.kind) {
      WorkspaceApprovalKind.information =>
        '批准的是固定字段集合。当前会话和期限内读取这些字段的最新内容，后来新增的字段不会加入。',
      WorkspaceApprovalKind.file =>
        '批准指定字段和附件版本后，Agent通过CLI领取受管副本。撤销或到期会阻止后续交付，但不能收回已经读到或上传的内容。普通附件与凭据文件分别管理。',
      WorkspaceApprovalKind.organization =>
        '只读取获准资料的元数据，并在固定资料范围和期限内自动调整目录与标签；不读改字段正文。整理完成后查看结果，不再进行第二次批准。最长30分钟。',
      WorkspaceApprovalKind.focus =>
        'Mac本机焦点填充尚未启用。本次只能查看申请与限制，不能批准填充。网页或工具的DOM焦点不代表系统前台焦点；未来真实能力由单独验收决定。',
      WorkspaceApprovalKind.credential =>
        '批准的是凭据固定版本、方式、接收配置和期限。CLI创建子进程并注入，秘密不作为普通字段返回。首个命令不是整个授权期的命令白名单；有效期内复用不续期，每次操作有独立结果，未知不重放。直接在系统shell执行含占位符的命令不会注入。',
    };
    await showDesktopDialog<void>(
      context,
      builder: (c) => DesktopDialog(
        title: const Text('这次授权如何使用'),
        content: Text(text, style: libraryText(c, 14, height: 1.9)),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('明白了'),
          ),
        ],
      ),
    );
  }

  Widget _credential(BuildContext context, WorkspaceCredentialUseRequest r) {
    final c = UiPalette.of(context),
        focus = r.delivery == WorkspaceCredentialDelivery.focus;
    Widget block(String label, String text) => Container(
      margin: const EdgeInsets.only(top: 15),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.rail,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: libraryText(context, 12, color: c.muted)),
          const SizedBox(height: 8),
          SelectableText(text, style: libraryText(context, 13, height: 1.9)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${r.credentialName} · 材料v${r.materialVersion}',
          style: libraryText(context, 14, weight: FontWeight.w600),
        ),
        block('注入位置', switch (r.delivery) {
          WorkspaceCredentialDelivery.environment =>
            '${r.receiver.binding} → 仅CLI创建的子进程环境变量',
          WorkspaceCredentialDelivery.file =>
            '${r.receiver.binding} → 临时凭据文件路径 → 已核对的参数位置',
          WorkspaceCredentialDelivery.focus => '本机前台窗口的真实输入焦点；Mac当前未启用',
          WorkspaceCredentialDelivery.storage => '仅保管，不提供运行时使用',
        }),
        if (!focus) ...[
          block(
            '由 CLI 启动',
            '${r.receiver.executable} ${r.receiver.arguments.map((a) => a.contains(RegExp(r'\s')) ? jsonEncode(a) : a).join(' ')}',
          ),
          block(
            '工作位置与接收方',
            '${r.receiver.workingDirectory}\n${r.receiver.label}',
          ),
          const SizedBox(height: 12),
          Text(
            '显示的是首个启动计划。授权期内可按批准方式复用，每次操作独立记录；不会在这里执行命令或返回凭据原文。',
            style: libraryText(context, 13, color: c.muted, height: 1.9),
          ),
        ],
      ],
    );
  }

  Widget _decision(BuildContext context, bool compact) {
    final c = UiPalette.of(context),
        detail = model.detail!,
        draft = model.draft!,
        r = detail.request,
        pending = r.state == WorkspaceApprovalState.pending,
        chosen = detail.scopes
            .where((x) => draft.selected.contains(x.id))
            .toList(),
        usesCredential = chosen.any(
          (x) => x.kind == WorkspaceApprovalScopeKind.credential,
        ),
        usesFields = chosen.any(
          (x) => x.kind != WorkspaceApprovalScopeKind.credential,
        ),
        enabled = model.canDecide && pending;
    Widget duration(bool credential) => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: DesktopSelect<int>(
        key: ValueKey(
          credential ? 'approval-credential-ttl' : 'approval-field-ttl',
        ),
        value: credential ? draft.credentialMinutes : draft.fieldMinutes,
        decoration: InputDecoration(
          labelText: credential
              ? '凭据期限'
              : '${r.kind == WorkspaceApprovalKind.organization ? '整理' : '普通范围'}期限',
        ),
        items: [
          for (final m
              in credential || r.kind == WorkspaceApprovalKind.organization
                  ? [15, 30]
                  : [15, 30, 60, 480])
            DropdownMenuItem(
              value: m,
              child: Text(m < 60 ? '$m 分钟' : '${m ~/ 60} 小时'),
            ),
        ],
        onChanged: enabled
            ? (v) {
                if (v != null) model.lifetime(v, credential: credential);
              }
            : null,
      ),
    );
    return Container(
      key: const ValueKey('approval-decision'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 18 : 23,
        vertical: compact ? 25 : 30,
      ),
      decoration: BoxDecoration(
        color: c.selected,
        border: compact
            ? Border(top: BorderSide(color: c.line))
            : Border(left: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pending ? '本次授权' : '本次决定',
            style: libraryText(context, 15, weight: FontWeight.w600),
          ),
          const SizedBox(height: 22),
          if (pending) ...[
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  '${draft.selected.length}',
                  style: libraryText(
                    context,
                    46,
                    color: c.accent,
                    weight: FontWeight.w500,
                  ),
                ),
                Text(
                  '/ ${detail.scopes.length} 项',
                  style: libraryText(context, 14, color: c.muted),
                ),
              ],
            ),
            if (usesFields) duration(false),
            if (usesCredential && r.kind != WorkspaceApprovalKind.focus)
              duration(true),
            const SizedBox(height: 18),
            Text(
              r.kind == WorkspaceApprovalKind.organization
                  ? '限定资料元数据与分类写入，最长30分钟。'
                  : '仅当前会话有效；批准范围内可复用，不随以后新增内容扩大。',
              style: libraryText(context, 13, color: c.muted, height: 1.9),
            ),
            if (detail.approveUnavailableReason != null)
              _message(context, detail.approveUnavailableReason!),
            const SizedBox(height: 20),
            DesktopButton(
              key: const ValueKey('approval-approve'),
              kind: DesktopButtonKind.primary,
              busy: model.busy,
              onPressed:
                  enabled && detail.canApprove && draft.selected.isNotEmpty
                  ? () => model.decide(WorkspaceApprovalAction.approve)
                  : null,
              child: const Text('批准所选范围'),
            ),
            const SizedBox(height: 10),
            DesktopButton(
              key: const ValueKey('approval-deny'),
              onPressed: enabled
                  ? () => model.decide(WorkspaceApprovalAction.deny)
                  : null,
              child: const Text('拒绝申请'),
            ),
          ] else ...[
            Text(
              r.state.label,
              style: libraryText(context, 25, color: c.accent),
            ),
            const SizedBox(height: 18),
            Text(
              '批准 ${detail.approved.length} 项',
              style: libraryText(context, 14),
            ),
            if (detail.fieldExpiresAt != null)
              Text(
                '普通范围至 ${libraryLocalDateTime(detail.fieldExpiresAt!)}',
                style: libraryText(context, 13, color: c.muted),
              ),
            if (detail.credentialExpiresAt != null)
              Text(
                '凭据至 ${libraryLocalDateTime(detail.credentialExpiresAt!)}',
                style: libraryText(context, 13, color: c.muted),
              ),
            if (r.state == WorkspaceApprovalState.approved) ...[
              const SizedBox(height: 22),
              DesktopButton(
                key: const ValueKey('approval-revoke'),
                kind: DesktopButtonKind.danger,
                onPressed: model.canDecide
                    ? () => model.decide(WorkspaceApprovalAction.revoke)
                    : null,
                child: const Text('撤销本次全部范围'),
              ),
            ],
            if (widget.onHistory != null) ...[
              const SizedBox(height: 12),
              DesktopButton(
                onPressed: model.frozen ? null : () => widget.onHistory!(r.id),
                child: const Text('查看授权历史'),
              ),
            ],
          ],
          if (model.notice != null) ...[
            const SizedBox(height: 14),
            _message(context, model.notice!),
          ],
          if (model.writeFailure != null) ...[
            const SizedBox(height: 14),
            _message(context, model.writeFailure!.message, error: true),
          ],
          if (model.uncertain)
            DesktopButton(
              key: const ValueKey('approval-reconcile'),
              onPressed: model.busy ? null : model.reconcile,
              child: const Text('核对本次结果'),
            ),
          if (model.needsReview || model.writeFailure?.code == 'conflict') ...[
            const SizedBox(height: 12),
            _message(context, '请求范围已变化，原选择已保留。请重新读取并核对。', error: true),
            DesktopButton(
              key: const ValueKey('approval-review-current'),
              onPressed: model.frozen ? null : model.reviewCurrent,
              child: const Text('重新读取并核对'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _content(BuildContext context, double width) {
    final c = UiPalette.of(context), d = model.detail;
    if (d == null) {
      return Center(
        child: Text(
          model.reading
              ? '正在读取请求…'
              : model.readFailure != null
              ? '请求读取失败，可重新读取。'
              : '选择请求查看申请范围。',
        ),
      );
    }
    final fold = MediaQuery.textScalerOf(context).scale(14) > 20 || width < 650;
    final content = Padding(
      key: const ValueKey('approval-content'),
      padding: EdgeInsets.all(width < 1000 ? 24 : 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 10,
            runSpacing: 8,
            children: [
              LibraryPill(
                d.request.state.label,
                color: d.request.state == WorkspaceApprovalState.pending
                    ? c.warning
                    : c.success,
                background: d.request.state == WorkspaceApprovalState.pending
                    ? c.credentialSurface
                    : c.successSurface,
              ),
              Text(
                '${d.request.agentClaim} · ${d.request.chatClaim}',
                style: libraryText(context, 12, color: c.muted),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(d.request.title, style: libraryHeading(context, 28)),
          const SizedBox(height: 14),
          Text(
            d.request.purpose,
            style: libraryText(context, 14, height: 1.95),
          ),
          const SizedBox(height: 14),
          Text(
            '聊天名称和用途由 Agent 自述，仅供判断。',
            style: libraryText(context, 12, color: c.muted),
          ),
          _section(context, '申请范围', _scopes(context)),
          _section(
            context,
            d.request.kind == WorkspaceApprovalKind.organization
                ? '整理范围'
                : d.credential == null
                ? '普通字段与文件'
                : '凭据使用方式',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DesktopButton(
                  key: const ValueKey('approval-tip'),
                  kind: DesktopButtonKind.quiet,
                  leading: const Icon(Icons.info_outline, size: 17),
                  alignment: Alignment.centerLeft,
                  onPressed: model.frozen ? null : () => _tip(context),
                  child: const Text('了解使用流程'),
                ),
                const SizedBox(height: 12),
                if (d.credential != null)
                  _credential(context, d.credential!)
                else
                  Text(
                    d.request.kind == WorkspaceApprovalKind.organization
                        ? '只读限定资料的元数据，并允许自动调整目录与标签；不读取字段值，不修改正文。'
                        : '只提供批准的固定字段和文件版本。新增内容不进入旧授权，撤销不能收回已经读到的副本。',
                    style: libraryText(context, 14, height: 1.95),
                  ),
              ],
            ),
          ),
          ApprovalExecutions(controller: model),
          _section(
            context,
            '关联资料',
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ref in d.scopes.map((s) => s.record).toSet())
                  DesktopButton(
                    key: ValueKey('approval-record-${ref.key}'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: model.frozen ? null : () => widget.onRecord(ref),
                    child: Text(
                      d.scopes.firstWhere((s) => s.record == ref).kind ==
                              WorkspaceApprovalScopeKind.credential
                          ? d.credential!.credentialName
                          : d.scopes
                                .firstWhere((s) => s.record == ref)
                                .section
                                .split(' · ')
                                .first,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return DesktopEntrance(
      key: ValueKey(d.request.id),
      child: Container(
        key: const ValueKey('approval-card'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.paper,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(11),
        ),
        child: fold
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [content, _decision(context, true)],
              )
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: content),
                    SizedBox(
                      width: width < 1000 ? 210 : 234,
                      child: _decision(context, false),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final c = UiPalette.of(context),
          result = model.results,
          sidebar = bounds.maxWidth <= 1300 ? 275.0 : 300.0;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: sidebar,
            decoration: BoxDecoration(
              color: c.rail,
              border: Border(right: BorderSide(color: c.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 25, 18, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '访问审批',
                        style: libraryText(
                          context,
                          23,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        result == null ? '尚未读取' : '${result.pending} 条待处理',
                        style: libraryText(context, 13, color: c.muted),
                      ),
                      const SizedBox(height: 20),
                      DesktopTextField(
                        key: const ValueKey('approval-search'),
                        controller: _search,
                        enabled: !model.frozen,
                        onChanged: model.search,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: '搜索请求',
                          labelText: '搜索请求',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 3,
                        children: [
                          for (final filter in WorkspaceApprovalFilter.values)
                            DesktopButton(
                              key: ValueKey('approval-filter-${filter.name}'),
                              kind: DesktopButtonKind.quiet,
                              selected: model.filter == filter,
                              onPressed: model.frozen
                                  ? null
                                  : () => model.setFilter(filter),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              child: Text(switch (filter) {
                                WorkspaceApprovalFilter.pending => '待处理',
                                WorkspaceApprovalFilter.all => '全部',
                                WorkspaceApprovalFilter.done => '已处理',
                              }),
                            ),
                        ],
                      ),
                      if (model.loading)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('正在读取请求…'),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    key: const ValueKey('approval-inbox-list'),
                    controller: _list,
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
                    children: [
                      if (result?.items.isEmpty == true)
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            '没有匹配的请求。',
                            style: libraryText(context, 13, color: c.muted),
                          ),
                        ),
                      for (final r
                          in result?.items ?? <WorkspaceApprovalSummary>[])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: DesktopButton(
                            key: ValueKey('approval-select-${r.id}'),
                            kind: DesktopButtonKind.quiet,
                            selected: model.selection == r.id,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 17,
                            ),
                            onPressed: model.frozen
                                ? null
                                : () => model.select(r.id),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  r.agentClaim,
                                  style: libraryText(
                                    context,
                                    12,
                                    color: c.muted,
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Text(
                                  r.title,
                                  style: libraryText(
                                    context,
                                    15,
                                    weight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    Text(
                                      r.kind.label,
                                      style: libraryText(
                                        context,
                                        12,
                                        color: c.muted,
                                      ),
                                    ),
                                    Text(
                                      r.state.label,
                                      style: libraryText(
                                        context,
                                        12,
                                        color: c.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (result != null && result.total > model.limit)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DesktopButton(
                          key: const ValueKey('approval-prev'),
                          onPressed: model.frozen || result.offset == 0
                              ? null
                              : () => model.page(result.offset - model.limit),
                          child: const Text('上一页'),
                        ),
                        Text(
                          '${result.offset ~/ model.limit + 1} / ${(result.total / model.limit).ceil()}',
                        ),
                        DesktopButton(
                          key: const ValueKey('approval-next'),
                          onPressed:
                              model.frozen ||
                                  result.offset + model.limit >= result.total
                              ? null
                              : () => model.page(result.offset + model.limit),
                          child: const Text('下一页'),
                        ),
                      ],
                    ),
                  ),
                if (widget.onSettings != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: DesktopButton(
                      kind: DesktopButtonKind.quiet,
                      onPressed: model.frozen ? null : widget.onSettings,
                      child: const Text('请求设置'),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: c.rail,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (model.readFailure != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _message(
                            context,
                            model.readFailure!.message,
                            error: true,
                          ),
                          DesktopButton(
                            key: const ValueKey('approval-retry'),
                            onPressed: model.frozen
                                ? null
                                : widget.onRetry ?? model.load,
                            child: const Text('重新读取'),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('approval-detail-scroll'),
                      controller: _detail,
                      padding: EdgeInsets.all(
                        bounds.maxWidth <= 1300 ? 19 : 24,
                      ),
                      child: _content(context, bounds.maxWidth - sidebar - 48),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
