import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'ui.dart';
import 'prototype_ui.dart';

String organizationStateLabel(OrganizationTaskState state) => switch (state) {
  OrganizationTaskState.pending => '待处理',
  OrganizationTaskState.active => '正在整理',
  OrganizationTaskState.proposed => '旧版方案待确认',
  OrganizationTaskState.confirmed => '整理完成',
  OrganizationTaskState.rejected => '已拒绝',
  OrganizationTaskState.cancelled => '已取消',
  OrganizationTaskState.expired => '已到期',
  OrganizationTaskState.conflicted => '资料已变化，整批未应用',
};

class OrganizationApprovalPanel extends StatefulWidget {
  const OrganizationApprovalPanel({
    super.key,
    required this.owner,
    required this.task,
    required this.selected,
    required this.onChanged,
    this.minutes,
    this.remainingSeconds = 0,
    this.onMinutesChanged,
  });
  final OwnerAccess owner;
  final OrganizationTask task;
  final Set<String> selected;
  final VoidCallback onChanged;
  final int? minutes;
  final int remainingSeconds;
  final ValueChanged<int>? onMinutesChanged;
  @override
  State<OrganizationApprovalPanel> createState() =>
      _OrganizationApprovalPanelState();
}

class _OrganizationApprovalPanelState extends State<OrganizationApprovalPanel> {
  bool _busy = false;
  int _draftMinutes = 30;
  int get _minutes => widget.minutes ?? _draftMinutes;
  void _chooseMinutes(int? value) {
    if (value == null) return;
    setState(() => _draftMinutes = value);
    widget.onMinutesChanged?.call(value);
  }

  final _documentScroll = ScrollController();
  @override
  void dispose() {
    _documentScroll.dispose();
    super.dispose();
  }

  String? _error;
  Future<void> _decide(bool approve) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (approve) {
        await widget.owner.approveOrganization(
          widget.task.id,
          widget.selected.toList(),
          lifetime: Duration(minutes: _minutes),
        );
      } else {
        await widget.owner.denyOrganization(widget.task.id);
      }
      widget.onChanged();
    } catch (_) {
      if (mounted) setState(() => _error = '未能保存决定，请检查范围、请求状态或存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.owner.cancelOrganization(widget.task.id);
      widget.onChanged();
    } catch (_) {
      if (mounted) setState(() => _error = '未能撤销整理，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final state = widget.owner.organizationState(task);
    final pending = state == OrganizationTaskState.pending;
    final c = UiPalette.of(context);
    final disabled = _busy || !widget.owner.serviceAvailable;
    final large = MediaQuery.textScalerOf(context).scale(14) > 20;
    Widget document() => Scrollbar(
      controller: _documentScroll,
      thumbVisibility: task.itemVersions.length > 6 || large,
      child: ListView(
        primary: false,
        controller: _documentScroll,
        key: PageStorageKey('organization-document-${task.id}'),
        padding: EdgeInsets.fromLTRB(30, large ? 10 : 24, 30, 24),
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: pending ? c.statusAttention : c.muted,
                    width: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                organizationStateLabel(state),
                style: prototypeText(
                  context,
                  12,
                  color: pending ? c.statusAttention : c.muted,
                ),
              ),
              const SizedBox(width: 12),
              Text('整理资料', style: prototypeText(context, 12, color: c.muted)),
              if (pending && !large) ...[
                const Spacer(),
                const PrototypeIcon(PrototypeIconGlyph.clock, size: 16),
                const SizedBox(width: 7),
                Text(
                  '还剩 ${(widget.remainingSeconds / 60).ceil()} 分钟',
                  style: prototypeText(context, 12, color: c.muted),
                ),
              ],
            ],
          ),
          if (!large) ...[
            const SizedBox(height: 12),
            Text(
              task.chatLabel,
              style: prototypeText(
                context,
                28,
                family: 'SimSun',
                weight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.selected,
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    task.agentName == 'Codex' ? 'C' : 'A',
                    style: prototypeText(
                      context,
                      16,
                      family: 'Georgia',
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  task.agentName.isEmpty ? 'Agent' : task.agentName,
                  style: prototypeText(context, 13, weight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text('当前聊天', style: prototypeText(context, 12, color: c.muted)),
                const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: task.id,
                    child: Text(
                      task.id.length > 12
                          ? '${task.id.substring(0, 8)}…'
                          : task.id,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: prototypeText(
                        context,
                        11,
                        color: c.muted,
                        family: 'Consolas',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              '申请用途',
              style: prototypeText(
                context,
                12,
                color: c.muted,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(task.purpose, style: prototypeText(context, 14, height: 1.9)),
          const SizedBox(height: 6),
          const PrototypeSelfDescription(),
          const SizedBox(height: 20),
          Divider(height: 1, color: c.line),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                '允许整理的资料',
                style: prototypeText(context, 16, weight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '仅元数据 · 不含字段值',
                style: prototypeText(context, 11, color: c.muted),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            '允许读取标题、公开说明、目录和标签，并调整分类与标签。',
            style: prototypeText(context, 13, height: 1.8),
          ),
          for (final id in task.itemVersions.keys)
            Builder(
              builder: (context) {
                final item = widget.owner.information
                    .where((i) => i.id == id)
                    .firstOrNull;
                final enabled = pending && !disabled && item != null;
                void change(bool? value) => setState(
                  () => value == true
                      ? widget.selected.add(id)
                      : widget.selected.remove(id),
                );
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: ValueKey('organize-item-$id'),
                    onTap: enabled
                        ? () => change(!widget.selected.contains(id))
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.line)),
                      ),
                      child: Row(
                        children: [
                          PrototypeCheck(
                            disabledSelectedColor: c.accent,
                            value: widget.selected.contains(id),
                            onChanged: enabled ? change : null,
                          ),
                          const SizedBox(width: 10),
                          const PrototypeIcon(PrototypeIconGlyph.file),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              item?.name ?? '资料已删除',
                              style: prototypeText(context, 14),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            fit: FlexFit.tight,
                            child: Text(
                              textAlign: TextAlign.right,
                              directoryPath(widget.owner, item?.directoryId),
                              style: prototypeText(context, 12, color: c.muted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 20),
          Text(
            '批准后可自动应用整理结果，无需再次确认；不读取或修改字段值。',
            style: prototypeText(context, 13, color: c.muted, height: 1.8),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const PrototypeIcon(PrototypeIconGlyph.shield, size: 16),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '资料范围固定；新增资料不会自动加入。',
                  style: prototypeText(
                    context,
                    11,
                    color: c.muted,
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    Widget decision(bool compact) => Container(
      padding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: compact ? 14 : 28,
      ),
      decoration: BoxDecoration(
        color: c.rail,
        border: Border(
          top: compact ? BorderSide(color: c.line) : BorderSide.none,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) ...[
            Text(
              '本次决定',
              style: prototypeText(
                context,
                11,
                color: c.muted,
                height: 21 / 11,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '允许哪些调整',
              style: prototypeText(
                context,
                23,
                family: 'SimSun',
                weight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 17),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${pending ? widget.selected.length : task.itemVersions.length}',
                  style: prototypeText(
                    context,
                    48,
                    family: 'Georgia',
                    height: 1.2,
                    color: c.strong,
                  ),
                ),
                const SizedBox(width: 11),
                Text('条信息', style: prototypeText(context, 12, color: c.muted)),
              ],
            ),
            const SizedBox(height: 25),
            Text(
              '读取整理所需元数据\n调整分类与标签',
              style: prototypeText(context, 13, color: c.muted, height: 2),
            ),
            const SizedBox(height: 28),
            Text('授权期限', style: prototypeText(context, 12)),
            const SizedBox(height: 9),
            Container(
              height: 41,
              padding: const EdgeInsets.only(left: 14, right: 4),
              decoration: BoxDecoration(
                color: c.paper,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(4),
              ),
              child: DesktopSelect<int>(
                isExpanded: true,
                key: ValueKey('organization-lifetime-${task.id}'),
                value: _minutes,
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 分钟')),
                  DropdownMenuItem(value: 30, child: Text('30 分钟')),
                ],
                onChanged: pending && !disabled ? _chooseMinutes : null,
              ),
            ),
          ],
          if (compact)
            Text(
              '最终选择 ${widget.selected.length} 条信息 · $_minutes 分钟',
              style: prototypeText(context, 12, color: c.muted),
            ),
          if (pending) const SizedBox(height: 24),
          if (pending) ...[
            FilledButton(
              onPressed: disabled || widget.selected.isEmpty
                  ? null
                  : () => _decide(true),
              style: prototypeButton(
                context,
                size: 13,
                foreground: Colors.white,
                background: c.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 13,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _busy ? '正在保存…' : '批准整理范围',
                    style: prototypeText(
                      context,
                      13,
                      color: Colors.white,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Text('→'),
                ],
              ),
            ),
            TextButton(
              onPressed: disabled ? null : () => _decide(false),
              style: prototypeButton(
                context,
                padding: const EdgeInsets.symmetric(vertical: 15),
                foreground: c.ink,
              ),
              child: const Text('拒绝请求'),
            ),
          ] else ...[
            const SizedBox(height: 20),
            Divider(height: 1, color: c.line),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PrototypeIcon(PrototypeIconGlyph.clock, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '此请求已处理。\n当前状态：${organizationStateLabel(state)}',
                    style: prototypeText(context, 12, color: c.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '截止 ${uiTime(task.expiresAt)}',
              style: prototypeText(context, 11, color: c.muted),
            ),
            if (state == OrganizationTaskState.active)
              OutlinedButton(
                onPressed: disabled ? null : _cancel,
                child: const Text('撤销整理'),
              ),
            if (state == OrganizationTaskState.conflicted)
              const Text('请让 Agent 根据当前资料重新申请。'),
            if (state == OrganizationTaskState.confirmed ||
                state == OrganizationTaskState.conflicted) ...[
              const SizedBox(height: 12),
              Text(
                '本次整理能力已结束，不能继续读取或调整分类。',
                style: prototypeText(context, 12, color: c.muted),
              ),
              TextButton(
                onPressed: () =>
                    showOrganizationResult(context, widget.owner, task.id),
                child: const Text('查看整理结果'),
              ),
            ],
          ],
          if (_error != null) QuietNotice(_error!, warning: true),
          const SizedBox(height: 16),
          Text(
            '仅本次会话有效。\n会话结束、完成或到期后失效。',
            style: prototypeText(context, 11, color: c.muted, height: 1.9),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth >= 780 && !large;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: document()),
              SizedBox(
                width: 244,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.rail,
                    border: Border(left: BorderSide(color: c.line)),
                  ),
                  child: SingleChildScrollView(child: decision(false)),
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: document()),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: bounds.maxHeight * .5),
              child: SingleChildScrollView(child: decision(true)),
            ),
          ],
        );
      },
    );
  }
}

Future<void> showOrganizationResult(
  BuildContext context,
  OwnerAccess owner,
  String taskId,
) {
  final task = owner.organizationTasks.where((t) => t.id == taskId).firstOrNull;
  if (task == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (_) => _ReviewOrganization(owner: owner, task: task),
  );
}

class OrganizationResultsList extends StatelessWidget {
  const OrganizationResultsList({
    super.key,
    required this.owner,
    required this.onChanged,
  });
  final OwnerAccess owner;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final task in owner.organizationTasks.reversed.where(
        (t) =>
            t.changes.isNotEmpty || t.state == OrganizationTaskState.confirmed,
      ))
        WorkspaceRecord(
          title: const Text('分类整理'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.purpose),
              const SizedBox(height: 6),
              Text(
                '提交 Agent  ${task.agentName.isEmpty ? '名称未记录' : task.agentName}',
              ),
              const SizedBox(height: 6),
              Text('聊天  ${task.chatLabel}'),
              const SizedBox(height: 6),
              Text('提交时间  ${uiTime(task.createdAt)}'),
              const SizedBox(height: 6),
              Text('调整 ${task.changes.length} 条信息'),
              for (final item
                  in owner.information
                      .where((i) => task.itemVersions.containsKey(i.id))
                      .take(3))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(item.name),
                ),
              const SizedBox(height: 6),
              StatusLabel(
                organizationStateLabel(owner.organizationState(task)),
                active: task.state == OrganizationTaskState.confirmed,
              ),
            ],
          ),
          trailing: OutlinedButton(
            onPressed: () async {
              await showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => _ReviewOrganization(owner: owner, task: task),
              );
              onChanged();
            },
            child: Text(
              task.state == OrganizationTaskState.proposed ? '查看旧版方案' : '查看结果',
            ),
          ),
        ),
    ],
  );
}

class _ReviewOrganization extends StatefulWidget {
  const _ReviewOrganization({required this.owner, required this.task});
  final OwnerAccess owner;
  final OrganizationTask task;
  @override
  State<_ReviewOrganization> createState() => _ReviewOrganizationState();
}

class _ReviewOrganizationState extends State<_ReviewOrganization> {
  bool _busy = false, _conflict = false;
  String? _error;
  bool get _pending => widget.task.state == OrganizationTaskState.proposed;
  Future<void> _decide(bool confirm) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (confirm) {
        await widget.owner.confirmOrganization(widget.task.id);
      } else {
        await widget.owner.rejectOrganization(widget.task.id);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _conflict =
              error is AccessFailure && error.status == 'organization_conflict';
          _error = _conflict
              ? '资料已变化，整批未应用。请关闭后重新发起整理。'
              : '未能保存方案，原分类保持不变。请检查存储后重试。';
        });
      }
    }
  }

  String _folder(String? id) =>
      id == null ? '未分类' : directoryPath(widget.owner, id);
  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text(_pending ? '查看整理方案' : '整理结果'),
    content: SizedBox(
      width: 760,
      height: (220 + widget.task.changes.length * 150)
          .clamp(220, 620)
          .toDouble(),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              primary: false,
              children: [
                Text(
                  '聊天：${widget.task.chatLabel}\n${widget.task.changes.length} 条整理结果',
                ),
                SelectableText('请求与授权：${widget.task.id}'),
                Text(
                  '批准时间：${uiTime(widget.task.approvedAt)} · 截止：${uiTime(widget.task.expiresAt)}',
                ),
                StatusLabel(
                  organizationStateLabel(
                    widget.owner.organizationState(widget.task),
                  ),
                  active: widget.task.state == OrganizationTaskState.confirmed,
                ),
                QuietNotice(
                  _pending
                      ? '这是旧版待确认方案，确认后才调整分类与标签。'
                      : widget.task.state == OrganizationTaskState.confirmed
                      ? (widget.task.changes.isEmpty
                            ? '本次未改动分类或标签。'
                            : '分类和标签调整已生效，内容和已有授权范围保持原样。')
                      : '本次方案未应用，未调整分类或标签。',
                  warning:
                      widget.task.state == OrganizationTaskState.conflicted,
                ),
                for (final change in widget.task.changes)
                  Builder(
                    builder: (context) {
                      final item = widget.owner.information
                          .where((i) => i.id == change.itemId)
                          .firstOrNull;
                      final proposedFolder = change.directoryId != null
                          ? _folder(change.directoryId)
                          : change.directoryName.isEmpty
                          ? '未分类'
                          : change.directoryName;
                      List<String> tagNames(Iterable<String> ids) => [
                        for (final id in ids)
                          widget.owner.tags
                                  .where((t) => t.id == id)
                                  .firstOrNull
                                  ?.name ??
                              '已移除标签',
                      ];
                      final proposedNames = {
                        ...tagNames(change.tagIds),
                        ...change.tagNames,
                      };
                      final oldNames = tagNames(item?.tagIds ?? []).toSet();
                      final tagsUnchanged =
                          oldNames.length == proposedNames.length &&
                          oldNames.every(proposedNames.contains);
                      final folderUnchanged =
                          _folder(item?.directoryId) == proposedFolder;
                      final proposedTags = proposedNames.join('、');
                      final oldTags = oldNames.join('、');
                      return FormSection(
                        title: item?.name ?? '资料已删除',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_pending) ...[
                              Text(
                                folderUnchanged
                                    ? '分类：$proposedFolder（保持）'
                                    : '分类：${_folder(item?.directoryId)} → $proposedFolder',
                                style: folderUnchanged
                                    ? Theme.of(context).textTheme.bodySmall
                                    : null,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                tagsUnchanged
                                    ? '标签：${proposedTags.isEmpty ? '无' : proposedTags}（保持）'
                                    : '标签：${oldTags.isEmpty ? '无' : oldTags} → ${proposedTags.isEmpty ? '无' : proposedTags}',
                                style: tagsUnchanged
                                    ? Theme.of(context).textTheme.bodySmall
                                    : null,
                              ),
                            ] else ...[
                              Text(
                                '${widget.task.state == OrganizationTaskState.confirmed ? '分类' : '拟调整分类'}：$proposedFolder',
                              ),
                              Text(
                                '${widget.task.state == OrganizationTaskState.confirmed ? '标签' : '拟调整标签'}：${proposedTags.isEmpty ? '无' : proposedTags}',
                              ),
                              if (item != null)
                                Text('当前分类：${_folder(item.directoryId)}'),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          if (_error != null) QuietNotice(_error!, warning: true),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy || !widget.owner.serviceAvailable
            ? null
            : () => Navigator.pop(context),
        child: Text(_pending && !_conflict ? '暂不处理' : '关闭'),
      ),
      if (_pending && !_conflict) ...[
        TextButton(
          onPressed: _busy || !widget.owner.serviceAvailable
              ? null
              : () => _decide(false),
          child: const Text('拒绝方案'),
        ),
        FilledButton(
          onPressed: _busy || !widget.owner.serviceAvailable
              ? null
              : () => _decide(true),
          child: Text(_busy ? '正在应用…' : '确认整批调整'),
        ),
      ],
    ],
  );
}
