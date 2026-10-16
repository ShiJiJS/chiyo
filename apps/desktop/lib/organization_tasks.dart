import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'ui.dart';

String organizationStateLabel(OrganizationTaskState state) => switch (state) {
  OrganizationTaskState.pending => '待审批',
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
  });
  final OwnerAccess owner;
  final OrganizationTask task;
  final Set<String> selected;
  final VoidCallback onChanged;
  @override
  State<OrganizationApprovalPanel> createState() =>
      _OrganizationApprovalPanelState();
}

class _OrganizationApprovalPanelState extends State<OrganizationApprovalPanel> {
  bool _busy = false;
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
    try {
      await widget.owner.cancelOrganization(widget.task.id);
      widget.onChanged();
    } catch (_) {
      if (mounted) setState(() => _error = '未能撤销整理，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final state = widget.owner.organizationState(task);
    final pending = state == OrganizationTaskState.pending;
    final document = ListView(
      children: [
        Text('整理分类与标签', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(task.purpose),
        const SizedBox(height: 8),
        Text(
          '提交 Agent（自述）：${task.agentName.isEmpty ? '名称未记录' : task.agentName}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          '聊天：${task.chatLabel}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        const QuietNotice(
          '仅提供所选信息的标题、说明和现有分类/标签名称，不提供字段值。批准后，Agent 可直接调整所选信息的分类与标签，无需再次确认。',
        ),
        const SizedBox(height: 12),
        for (final id in task.itemVersions.keys)
          Builder(
            builder: (context) {
              final item = widget.owner.information
                  .where((i) => i.id == id)
                  .firstOrNull;
              return pending
                  ? CheckboxListTile(
                      key: ValueKey('organize-item-$id'),
                      value: widget.selected.contains(id),
                      onChanged: _busy || item == null
                          ? null
                          : (value) => setState(() {
                              value == true
                                  ? widget.selected.add(id)
                                  : widget.selected.remove(id);
                            }),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(item?.name ?? '资料已删除'),
                      subtitle: item == null
                          ? null
                          : Text(
                              item.description.isEmpty
                                  ? directoryPath(
                                      widget.owner,
                                      item.directoryId,
                                    )
                                  : item.description,
                            ),
                    )
                  : WorkspaceRecord(title: Text(item?.name ?? '资料已删除'));
            },
          ),
      ],
    );
    final decision = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: UiColors.rail,
        border: Border.all(color: UiColors.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusLabel(
            organizationStateLabel(state),
            active: state == OrganizationTaskState.confirmed,
            attention: pending,
          ),
          const SizedBox(height: 12),
          Text(
            '${pending ? widget.selected.length : task.itemVersions.length} 条信息',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            pending ? '批准后最长 30 分钟，完成后结束访问。' : '截止 ${uiTime(task.expiresAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null) QuietNotice(_error!, warning: true),
          const SizedBox(height: 12),
          if (pending)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _decide(false),
                  child: const Text('拒绝'),
                ),
                FilledButton(
                  onPressed: _busy || widget.selected.isEmpty
                      ? null
                      : () => _decide(true),
                  child: Text(_busy ? '正在保存…' : '批准整理'),
                ),
              ],
            )
          else if (state == OrganizationTaskState.active)
            OutlinedButton(
              onPressed: _busy ? null : _cancel,
              child: const Text('撤销整理'),
            ),
          if (state == OrganizationTaskState.conflicted)
            const Text('请让 Agent 根据当前资料重新申请。'),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (bounds.maxWidth >= 900 &&
            MediaQuery.textScalerOf(context).scale(14) <= 20) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: document),
              const SizedBox(width: 24),
              SizedBox(
                width: 340,
                child: SingleChildScrollView(child: decision),
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: document),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: bounds.maxHeight * .5),
              child: SingleChildScrollView(child: decision),
            ),
          ],
        );
      },
    );
  }
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
              children: [
                Text(
                  '聊天：${widget.task.chatLabel}\n${widget.task.changes.length} 条整理结果',
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
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(_pending && !_conflict ? '暂不处理' : '关闭'),
      ),
      if (_pending && !_conflict) ...[
        TextButton(
          onPressed: _busy ? null : () => _decide(false),
          child: const Text('拒绝方案'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _decide(true),
          child: Text(_busy ? '正在应用…' : '确认整批调整'),
        ),
      ],
    ],
  );
}
