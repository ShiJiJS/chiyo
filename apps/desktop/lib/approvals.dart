import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'organization_tasks.dart';
import 'ui.dart';

class _ApprovalEntry {
  _ApprovalEntry.access(this.access)
    : organization = null,
      organizationState = null;
  _ApprovalEntry.organization(this.organization, this.organizationState)
    : access = null;
  final OwnerRequestSnapshot? access;
  final OrganizationTask? organization;
  final OrganizationTaskState? organizationState;
  String get id => access?.id ?? organization!.id;
  String get chatLabel => access?.chatLabel ?? organization!.chatLabel;
  bool get pending =>
      access?.state == AccessRequestState.pending ||
      organizationState == OrganizationTaskState.pending;
}

class Approvals extends StatefulWidget {
  const Approvals({super.key, required this.service, required this.port});
  final InformationService service;
  final int port;
  @override
  State<Approvals> createState() => ApprovalsState();
}

class ApprovalsState extends State<Approvals> {
  Timer? _refresh;
  final _requestsScroll = ScrollController();
  final _scopeScroll = ScrollController();
  String? _actionError;
  String? _focused;
  final _selection = <String, Set<FieldRef>>{};
  final _organizationSelection = <String, Set<String>>{};
  final _grantMinutes = <String, int>{};
  final _expandedScope = <String>{};
  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _requestsScroll.dispose();
    _scopeScroll.dispose();
    super.dispose();
  }

  void _manage(VoidCallback action) {
    try {
      action();
      setState(() => _actionError = null);
    } on AccessFailure catch (error) {
      setState(
        () => _actionError = switch (error.status) {
          'invalid_scope' => '所选字段已不可用，或超过200个。请重新检查最终选择。',
          'invalid_duration' => '授权有效期须为1至10080分钟。',
          _ => '请求状态已变化，请重新检查。',
        },
      );
    }
  }

  Future<void> _settings() => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => DesktopDialog(
        title: const Text('请求设置'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('待审批有效期'),
              const SizedBox(height: 12),
              DesktopSelect<int>(
                key: const ValueKey('request-lifetime'),
                value: widget.service.owner.requestLifetime.inMinutes,
                isExpanded: true,
                items:
                    {
                          5,
                          15,
                          30,
                          60,
                          120,
                          widget.service.owner.requestLifetime.inMinutes,
                        }
                        .map(
                          (minutes) => DropdownMenuItem(
                            value: minutes,
                            child: Text('$minutes 分钟'),
                          ),
                        )
                        .toList(),
                onChanged: (minutes) async {
                  if (minutes == null) return;
                  try {
                    await Future<void>.sync(
                      () => widget.service.owner.setRequestLifetime(
                        Duration(minutes: minutes),
                      ),
                    );
                    if (context.mounted) update(() {});
                  } on Object {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('设置未保存，请重试。')),
                      );
                    }
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text('仅影响新申请，已经提交的申请不会延长。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final requests = [
      for (final r in widget.service.owner.requests) _ApprovalEntry.access(r),
      for (final task in widget.service.owner.organizationTasks)
        _ApprovalEntry.organization(
          task,
          widget.service.owner.organizationState(task),
        ),
    ];
    requests.sort((a, b) => (a.pending ? 0 : 1).compareTo(b.pending ? 0 : 1));
    if (!requests.any((r) => r.id == _focused)) {
      _focused = requests.firstOrNull?.id;
    }
    final current = requests.where((r) => r.id == _focused).firstOrNull;
    final pending = requests.where((r) => r.pending).length;
    final largeType = MediaQuery.textScalerOf(context).scale(14) > 20;
    return Scaffold(
      body: Padding(
        padding: UiSpace.page,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (largeType)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: requests.length > 1
                          ? DesktopSelect<String>(
                              key: const ValueKey('request-picker'),
                              value: current?.id,
                              isExpanded: true,
                              items: [
                                for (final r in requests)
                                  DropdownMenuItem(
                                    value: r.id,
                                    child: Text(
                                      '${r.chatLabel} · ${_entryState(r)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (id) => setState(() {
                                _focused = id;
                                _actionError = null;
                                if (_scopeScroll.hasClients) {
                                  _scopeScroll.jumpTo(0);
                                }
                              }),
                            )
                          : Text(
                              '$pending 条待处理 · ${requests.length} 条申请',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                    ),
                    const SizedBox(width: 16),
                    OutlinedButton.icon(
                      onPressed: _settings,
                      icon: const Icon(Icons.tune, size: 17),
                      label: const Text('请求设置'),
                    ),
                  ],
                ),
              )
            else
              PageHeading(
                '访问审批',
                subtitle: '$pending 条待处理 · ${requests.length} 条申请',
                actions: [
                  OutlinedButton.icon(
                    onPressed: _settings,
                    icon: const Icon(Icons.tune, size: 17),
                    label: const Text('请求设置'),
                  ),
                ],
              ),
            if (widget.service.owner.auditStorageUnavailable)
              const QuietNotice(
                '记录保存异常，信息读取已暂停。请修复存储后到“授权历史”重试保存记录。',
                warning: true,
              ),
            if (requests.length > 1 && !largeType) ...[
              SizedBox(
                height: 54,
                child: Scrollbar(
                  controller: _requestsScroll,
                  child: ListView.separated(
                    controller: _requestsScroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 10),
                    itemCount: requests.length,
                    separatorBuilder: (_, index) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _requestChoice(requests[i]),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: current == null
                  ? const EmptyWorkspace(
                      icon: Icons.inbox_outlined,
                      title: '暂无访问请求',
                      description: 'Agent 提交申请后，这里会列出用途和所需信息。\n批准前可以调整提供范围。',
                    )
                  : current.organization != null
                  ? OrganizationApprovalPanel(
                      key: ValueKey(current.id),
                      owner: widget.service.owner,
                      task: current.organization!,
                      selected: _organizationSelection.putIfAbsent(
                        current.id,
                        () => current.organization!.itemVersions.keys.toSet(),
                      ),
                      onChanged: () => setState(() {}),
                    )
                  : _requestView(current.access!),
            ),
          ],
        ),
      ),
    );
  }

  String _entryState(_ApprovalEntry entry) => entry.access != null
      ? _state(entry.access!.state)
      : '整理 · ${organizationStateLabel(entry.organizationState!)}';
  Widget _requestChoice(_ApprovalEntry request) {
    final selected = _focused == request.id;
    return SizedBox(
      width: 320,
      child: Material(
        color: selected ? UiColors.selected : Colors.transparent,
        child: InkWell(
          key: ValueKey('request-${request.id}'),
          onTap: () => setState(() {
            _focused = request.id;
            _actionError = null;
            if (_scopeScroll.hasClients) _scopeScroll.jumpTo(0);
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? UiColors.accent : UiColors.line,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    request.chatLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _entryState(request),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: request.pending ? UiColors.warning : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _requestView(OwnerRequestSnapshot request) {
    final selected = _selection.putIfAbsent(
      request.id,
      () => request.fields.toSet(),
    );
    final available = widget.service.owner.information
        .expand((item) => item.fields.map((f) => FieldRef(item.id, f.id)))
        .toSet();
    return LayoutBuilder(
      builder: (context, size) {
        final wide =
            size.maxWidth >= 900 &&
            MediaQuery.textScalerOf(context).scale(14) <= 20;
        final document = _requestDocument(request, selected, available);
        final decision = _decision(request, selected, compact: !wide);
        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: document),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 360,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: size.maxHeight),
                        child: decision,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  Expanded(child: document),
                  if (request.state == AccessRequestState.pending)
                    decision
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: size.maxHeight * .55,
                      ),
                      child: decision,
                    ),
                ],
              );
      },
    );
  }

  Widget _requestDocument(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected,
    Set<FieldRef> available,
  ) {
    final pending = request.state == AccessRequestState.pending;
    final expanded = _expandedScope.contains(request.id);
    final extras = {
      ...available,
      ...selected,
    }.where((f) => !request.fields.contains(f)).toList();
    final groups = <String, List<FieldRef>>{};
    for (final field in request.fields) {
      groups.putIfAbsent(field.itemId, () => []).add(field);
    }
    return ListView(
      key: PageStorageKey('detail-${request.id}'),
      padding: const EdgeInsets.fromLTRB(4, 14, 10, 20),
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusLabel(
              _state(request.state),
              active: request.state == AccessRequestState.approved,
              attention: pending,
            ),
            if (pending)
              Text(
                '待审批剩余：${request.remainingSeconds ~/ 60} 分 ${request.remainingSeconds % 60} 秒',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '聊天：${request.chatLabel}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(request.purpose, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 8),
        Text(
          '聊天名称与用途由 agent 自述，仅供判断。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        SectionHeading('Agent 申请范围', detail: '${request.fields.length} 个字段'),
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              widget.service.owner.information
                      .where((item) => item.id == group.key)
                      .firstOrNull
                      ?.name ??
                  '原信息已不可用',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final field in group.value)
            pending
                ? _scopeField(field, selected, available)
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      widget.service.owner.information
                              .where((i) => i.id == field.itemId)
                              .firstOrNull
                              ?.fields
                              .where((f) => f.id == field.fieldId)
                              .firstOrNull
                              ?.name ??
                          field.fieldId,
                    ),
                  ),
          const SizedBox(height: 14),
        ],
        if (pending) ...[
          if (!expanded && extras.any(selected.contains)) ...[
            const SectionHeading('补选的字段'),
            for (final field in extras.where(selected.contains))
              _scopeField(field, selected, available),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                expanded
                    ? _expandedScope.remove(request.id)
                    : _expandedScope.add(request.id);
              }),
              icon: Icon(expanded ? Icons.expand_less : Icons.add, size: 17),
              label: Text(expanded ? '收起补选范围' : '补选或改选字段'),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 12),
            for (final directory in widget.service.owner.directories)
              _directorySelection(request.id, directory, selected),
            for (final field in extras) _scopeField(field, selected, available),
          ],
        ],
        if (MediaQuery.sizeOf(context).width < 1100 ||
            MediaQuery.textScalerOf(context).scale(14) > 20)
          const QuietNotice('仅提供选中字段；新增内容需另行申请。撤销无法收回已提供的内容。'),
      ],
    );
  }

  Widget _decision(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected, {
    required bool compact,
  }) {
    final pending = request.state == AccessRequestState.pending;
    final minutes = _grantMinutes[request.id] ?? 480;
    final valid = minutes >= 1 && minutes <= 10080;
    final lifetime = SizedBox(
      width: compact ? 176 : double.infinity,
      child: DesktopTextFormField(
        key: ValueKey('grant-lifetime-${request.id}'),
        initialValue: '$minutes',
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: compact ? null : '有效期（分钟）',
          suffixText: compact ? '分钟' : null,
          helperText: !compact && valid
              ? '${_durationLabel(minutes)} · 读取不续期'
              : null,
          errorText: valid ? null : '请输入 1 至 10080 的整数',
        ),
        onChanged: (v) => setState(() {
          _grantMinutes[request.id] = int.tryParse(v) ?? 0;
          _actionError = null;
        }),
      ),
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton(
          onPressed: () => _manage(() => widget.service.owner.deny(request.id)),
          child: const Text('拒绝申请'),
        ),
        FilledButton.icon(
          key: const ValueKey('approve-selection'),
          onPressed: selected.isEmpty || !valid
              ? null
              : () => _manage(
                  () => widget.service.owner.approve(
                    request.id,
                    selected.toList(),
                    lifetime: Duration(minutes: minutes),
                  ),
                ),
          icon: const Icon(Icons.check, size: 17),
          label: const Text('批准所选字段'),
        ),
      ],
    );
    final policy = Text(
      '仅提供选中字段；新增内容需另行申请。撤销无法收回已提供的内容。',
      style: Theme.of(context).textTheme.bodySmall,
    );
    if (!pending) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: UiColors.rail,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeading('本次申请已处理'),
            if (request.sessionEnded)
              const QuietNotice('聊天已结束。恢复聊天需要重新连接并申请授权。'),
            if (request.approvedFields != null) ...[
              Flexible(
                fit: FlexFit.loose,
                child: Scrollbar(
                  controller: _scopeScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scopeScroll,
                    child: request.approvedFields!.length == 1
                        ? Text(
                            '已批准字段：${request.approvedFields!.map(_fieldLabel).join('、')}',
                          )
                        : _scopeGroups(request.approvedFields!),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '到期时间：${uiTime(request.grantExpiresAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (request.state == AccessRequestState.approved)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: () =>
                        _manage(() => widget.service.owner.revoke(request.id)),
                    child: const Text('撤销授权'),
                  ),
                ),
              ),
            if (_actionError != null) QuietNotice(_actionError!, warning: true),
          ],
        ),
      );
    }
    return Container(
      key: ValueKey('decision-${request.id}'),
      padding: EdgeInsets.all(compact ? 14 : 22),
      decoration: BoxDecoration(
        color: UiColors.rail,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: UiColors.line),
      ),
      child: compact
          ? LayoutBuilder(
              builder: (context, bounds) {
                final summary = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => DesktopDialog(
                          title: Text('本次授权范围 · ${selected.length} 个字段'),
                          content: SizedBox(
                            width: 600,
                            height: 420,
                            child: SingleChildScrollView(
                              child: _scopeGroups(selected),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('返回审批'),
                            ),
                          ],
                        ),
                      ),
                      child: Text('最终选择 ${selected.length} 个字段'),
                    ),
                    Text(
                      valid
                          ? '有效期 ${_durationLabel(minutes)} · 读取不续期'
                          : '有效期有误',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
                final controls = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(label: '授权有效期（分钟）', child: lifetime),
                    const SizedBox(width: 16),
                    actions,
                  ],
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (bounds.maxWidth >= 650)
                      Row(
                        children: [
                          Expanded(child: summary),
                          const SizedBox(width: 12),
                          controls,
                        ],
                      )
                    else ...[
                      summary,
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [lifetime, actions],
                      ),
                    ],
                    if (_actionError != null)
                      QuietNotice(_actionError!, warning: true),
                  ],
                );
              },
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeading('本次授权'),
                Text(
                  request.chatLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Flexible(
                  fit: FlexFit.loose,
                  child: Scrollbar(
                    controller: _scopeScroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scopeScroll,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '最终选择 ${selected.length} 个字段',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          if (selected.isEmpty)
                            const Text('尚未选择字段')
                          else
                            _scopeGroups(selected),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                lifetime,
                const SizedBox(height: 8),
                actions,
                if (_actionError != null)
                  QuietNotice(_actionError!, warning: true),
                const SizedBox(height: 18),
                policy,
              ],
            ),
    );
  }

  Widget _scopeGroups(Iterable<FieldRef> refs) {
    final groups = <String, List<FieldRef>>{};
    for (final ref in refs) {
      groups.putIfAbsent(ref.itemId, () => []).add(ref);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              widget.service.owner.information
                      .where((i) => i.id == group.key)
                      .firstOrNull
                      ?.name ??
                  group.key,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final ref in group.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Text(
                '· ${widget.service.owner.information.where((i) => i.id == ref.itemId).firstOrNull?.fields.where((f) => f.id == ref.fieldId).firstOrNull?.name ?? ref.fieldId}',
              ),
            ),
        ],
      ],
    );
  }

  Widget _scopeField(
    FieldRef ref,
    Set<FieldRef> selected,
    Set<FieldRef> available,
  ) {
    final item = widget.service.owner.information
        .where((i) => i.id == ref.itemId)
        .firstOrNull;
    final field = item?.fields.where((f) => f.id == ref.fieldId).firstOrNull;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: UiColors.line)),
        ),
        child: CheckboxListTile(
          key: ValueKey('field-${ref.fieldId}'),
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 2,
            vertical: 0,
          ),
          title: Text(field?.name ?? _fieldLabel(ref)),
          subtitle: !available.contains(ref)
              ? const Text(
                  '字段已不可用，请取消选择或改选其他字段',
                  style: TextStyle(color: UiColors.danger),
                )
              : field?.description.isNotEmpty == true
              ? Text(field!.description)
              : null,
          value: selected.contains(ref),
          onChanged: (v) => setState(() {
            v == true ? selected.add(ref) : selected.remove(ref);
            _actionError = null;
          }),
        ),
      ),
    );
  }

  String _fieldLabel(FieldRef ref) {
    for (final item in widget.service.owner.information) {
      if (item.id != ref.itemId) continue;
      for (final field in item.fields) {
        if (field.id == ref.fieldId) return '${item.name} · ${field.name}';
      }
    }
    return '${ref.itemId} / ${ref.fieldId}';
  }

  String _durationLabel(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final remaining = minutes % 60;
    return remaining == 0 ? '$hours 小时' : '$hours 小时 $remaining 分钟';
  }

  String _state(AccessRequestState state) => switch (state) {
    AccessRequestState.pending => '待审批',
    AccessRequestState.approved => '已批准',
    AccessRequestState.revoked => '已撤销',
    AccessRequestState.denied => '已拒绝',
    AccessRequestState.cancelled => '已取消',
    AccessRequestState.expired => '已过期',
  };

  Widget _directorySelection(
    String requestId,
    InformationDirectory directory,
    Set<FieldRef> selected,
  ) {
    final fields = widget.service.owner.fieldsInDirectory(directory.id);
    final count = fields.where(selected.contains).length;
    return CheckboxListTile(
      key: ValueKey('directory-$requestId-${directory.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text('按目录选择：${directoryPath(widget.service.owner, directory.id)}'),
      subtitle: Text('包含下级目录当前 ${fields.length} 个字段；不会自动加入新增内容。'),
      tristate: true,
      value: count == 0
          ? false
          : count == fields.length
          ? true
          : null,
      onChanged: fields.isEmpty
          ? null
          : (value) => setState(() {
              if (value == true) {
                selected.addAll(fields);
              } else {
                selected.removeAll(fields);
              }
            }),
    );
  }
}
