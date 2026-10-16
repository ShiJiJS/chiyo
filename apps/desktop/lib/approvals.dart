import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'ui.dart';

class Approvals extends StatefulWidget {
  const Approvals({super.key, required this.service, required this.port});
  final InformationService service;
  final int port;
  @override
  State<Approvals> createState() => ApprovalsState();
}

class ApprovalsState extends State<Approvals> {
  Timer? _refresh;
  String? _focused;
  final _selection = <String, Set<FieldRef>>{};
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
    super.dispose();
  }

  void _manage(VoidCallback action) {
    try {
      action();
      setState(() {});
    } on AccessFailure catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (error.status) {
            'invalid_scope' => '所选字段已不可用，或超过 200 个。请重新检查最终选择。',
            'invalid_duration' => '授权有效期须为 1 至 10080 分钟。',
            _ => '请求状态已变化，请重新检查。',
          }),
        ),
      );
      setState(() {});
    }
  }

  Future<void> _settings() => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('请求设置'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('待审批有效期'),
              const SizedBox(height: 12),
              DropdownButton<int>(
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
    final requests = widget.service.owner.requests.toList();
    requests.sort(
      (a, b) => (a.state == AccessRequestState.pending ? 0 : 1).compareTo(
        b.state == AccessRequestState.pending ? 0 : 1,
      ),
    );
    if (!requests.any((r) => r.id == _focused)) {
      _focused = requests.firstOrNull?.id;
    }
    final current = requests.where((r) => r.id == _focused).firstOrNull;
    final pending = requests
        .where((r) => r.state == AccessRequestState.pending)
        .length;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(26, 25, 26, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeading(
              '访问审批',
              subtitle: pending == 0
                  ? '在这里决定每次聊天可以读取的范围。'
                  : '$pending 个申请等待你的决定',
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
            Expanded(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: UiColors.line),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final detail = current == null
                          ? const EmptyWorkspace(
                              icon: Icons.inbox_outlined,
                              title: '暂无访问请求',
                              description:
                                  'Agent 提交申请后，这里会列出用途和所需信息。\n批准前可以调整提供范围。',
                            )
                          : _requestView(current);
                      if (constraints.maxWidth < 880 ||
                          MediaQuery.textScalerOf(context).scale(14) > 20) {
                        return Column(
                          children: [
                            if (requests.length > 1)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  8,
                                  18,
                                  0,
                                ),
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: _focused,
                                  items: requests
                                      .map(
                                        (r) => DropdownMenuItem(
                                          value: r.id,
                                          child: Text(
                                            r.chatLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (id) =>
                                      setState(() => _focused = id),
                                ),
                              ),
                            Expanded(child: detail),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          SizedBox(
                            width: 274,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    20,
                                    18,
                                    14,
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        '申请队列',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      const Spacer(),
                                      Text(
                                        '${requests.length}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: requests.isEmpty
                                      ? const Padding(
                                          padding: EdgeInsets.all(18),
                                          child: Text(
                                            '暂时没有申请',
                                            style: TextStyle(
                                              color: UiColors.muted,
                                            ),
                                          ),
                                        )
                                      : ListView(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          children: [
                                            for (final request in requests)
                                              _queueRow(request),
                                          ],
                                        ),
                                ),
                              ],
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: detail),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueRow(OwnerRequestSnapshot request) {
    final selected = _focused == request.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: selected ? UiColors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: InkWell(
          key: ValueKey('request-${request.id}'),
          borderRadius: BorderRadius.circular(7),
          onTap: () => setState(() => _focused = request.id),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.chatLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? UiColors.green : UiColors.ink,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  request.purpose,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 13),
                Row(
                  children: [
                    Expanded(
                      child: StatusLabel(
                        _state(request.state),
                        active: request.state == AccessRequestState.pending,
                      ),
                    ),
                    Text(
                      '${request.approvedFields?.length ?? request.fields.length} 个字段',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _requestView(OwnerRequestSnapshot request) {
    final id = request.id;
    final fields = request.fields;
    final selected = _selection.putIfAbsent(id, () => fields.toSet());
    final minutes = _grantMinutes[id] ?? 480;
    final validDuration = minutes >= 1 && minutes <= 10080;
    final available = widget.service.owner.information
        .expand(
          (item) => item.fields.map((field) => FieldRef(item.id, field.id)),
        )
        .toSet();
    final pending = request.state == AccessRequestState.pending;
    final expanded = _expandedScope.contains(id);
    final extras = {
      ...available,
      ...selected,
    }.where((f) => !fields.contains(f)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            key: PageStorageKey('detail-$id'),
            padding: const EdgeInsets.all(25),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '聊天：${request.chatLabel}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (!pending) ...[
                    const SizedBox(width: 12),
                    StatusLabel(
                      _state(request.state),
                      active: request.state == AccessRequestState.approved,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(
                request.purpose,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 6),
              Text(
                '聊天名称与用途由 agent 自述，仅供判断。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 22),
              if (pending) ...[
                Text(
                  '待审批剩余：${request.remainingSeconds ~/ 60} 分 ${request.remainingSeconds % 60} 秒',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Agent 申请范围',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      '${fields.length} 个字段',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final field in fields)
                  _fieldRow(field, selected, available, requested: true),
                if (!expanded && extras.any(selected.contains)) ...[
                  const SizedBox(height: 14),
                  Text('补选的字段', style: Theme.of(context).textTheme.titleSmall),
                  for (final field in extras.where(selected.contains))
                    _fieldRow(field, selected, available, requested: false),
                ],
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() {
                      if (expanded) {
                        _expandedScope.remove(id);
                      } else {
                        _expandedScope.add(id);
                      }
                    }),
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.add,
                      size: 18,
                    ),
                    label: Text(expanded ? '收起补选范围' : '补选或改选字段'),
                  ),
                ),
                if (expanded) ...[
                  const SizedBox(height: 10),
                  for (final directory in widget.service.owner.directories)
                    _directorySelection(id, directory, selected),
                  for (final field in extras)
                    _fieldRow(field, selected, available, requested: false),
                ],
                const SizedBox(height: 18),
              ] else ...[
                Text(
                  'Agent 申请范围',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final field in fields)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(_fieldLabel(field)),
                  ),
                const SizedBox(height: 22),
                if (request.approvedFields != null) ...[
                  Text(
                    '已批准字段：${request.approvedFields!.map(_fieldLabel).join('、')}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '到期时间：${uiTime(request.grantExpiresAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (request.sessionEnded)
                  const QuietNotice('聊天已结束。恢复聊天需要重新连接并申请授权。'),
              ],
            ],
          ),
        ),
        Container(
          key: ValueKey('decision-$id'),
          padding: const EdgeInsets.fromLTRB(22, 17, 22, 18),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: UiColors.line)),
          ),
          child: pending
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.checklist_outlined,
                          size: 18,
                          color: UiColors.green,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '最终选择（${selected.length} 个字段）：${selected.isEmpty ? '尚未选择字段' : selected.map(_fieldLabel).join('、')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final textScale =
                            MediaQuery.textScalerOf(context).scale(14) / 14;
                        final stacked = constraints.maxWidth < 520 * textScale;
                        final lifetime = SizedBox(
                          width: stacked ? double.infinity : 210 * textScale,
                          child: TextFormField(
                            key: ValueKey('grant-lifetime-$id'),
                            initialValue: '$minutes',
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: '有效期（分钟）',
                              helperText: validDuration
                                  ? '${_durationLabel(minutes)} · 读取不续期'
                                  : null,
                              errorText: validDuration
                                  ? null
                                  : '请输入 1 至 10080 的整数',
                            ),
                            onChanged: (value) => setState(
                              () =>
                                  _grantMinutes[id] = int.tryParse(value) ?? 0,
                            ),
                          ),
                        );
                        final actions = Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  _manage(() => widget.service.owner.deny(id)),
                              child: const Text('拒绝申请'),
                            ),
                            FilledButton.icon(
                              key: const ValueKey('approve-selection'),
                              onPressed: selected.isEmpty || !validDuration
                                  ? null
                                  : () => _manage(
                                      () => widget.service.owner.approve(
                                        id,
                                        selected.toList(),
                                        lifetime: Duration(minutes: minutes),
                                      ),
                                    ),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('批准所选字段'),
                            ),
                          ],
                        );
                        return stacked
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  lifetime,
                                  const SizedBox(height: 12),
                                  actions,
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [lifetime, const Spacer(), actions],
                              );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '仅提供选中字段；新增内容需另行申请。撤销无法收回已提供的内容。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Icon(Icons.task_alt, size: 18, color: UiColors.muted),
                    const SizedBox(width: 9),
                    const Expanded(
                      child: Text(
                        '本次申请已处理',
                        style: TextStyle(color: UiColors.muted),
                      ),
                    ),
                    if (request.state == AccessRequestState.approved)
                      OutlinedButton(
                        onPressed: () =>
                            _manage(() => widget.service.owner.revoke(id)),
                        child: const Text('撤销授权'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _fieldRow(
    FieldRef field,
    Set<FieldRef> selected,
    Set<FieldRef> available, {
    required bool requested,
  }) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150),
    margin: const EdgeInsets.symmetric(vertical: 3),
    decoration: BoxDecoration(
      color: selected.contains(field)
          ? const Color(0xfff0f6f2)
          : const Color(0xfffafbfa),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: CheckboxListTile(
        key: ValueKey('field-${field.fieldId}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(_fieldLabel(field), style: const TextStyle(fontSize: 14)),
        subtitle: !available.contains(field)
            ? const Text(
                '字段已不可用，请取消选择或改选其他字段',
                style: TextStyle(color: UiColors.danger),
              )
            : null,
        value: selected.contains(field),
        onChanged: (value) => setState(() {
          if (value == true) {
            selected.add(field);
          } else {
            selected.remove(field);
          }
        }),
      ),
    ),
  );

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
