import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'ui.dart';

class OrganizationTasksPage extends StatefulWidget {
  const OrganizationTasksPage({
    super.key,
    required this.owner,
    required this.itemIds,
  });
  final OwnerAccess owner;
  final List<String> itemIds;
  @override
  State<OrganizationTasksPage> createState() => _OrganizationTasksPageState();
}

class _OrganizationTasksPageState extends State<OrganizationTasksPage> {
  late final Timer _refresh;
  String? _error;
  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _StartOrganization(owner: widget.owner, itemIds: widget.itemIds),
    );
    if (mounted) setState(() {});
  }

  Future<void> _cancel(String id) async {
    try {
      await widget.owner.cancelOrganization(id);
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = '未能取消任务，请重试。');
    }
  }

  Future<void> _view(OrganizationTask task) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReviewOrganization(owner: widget.owner, task: task),
    );
    if (mounted) setState(() {});
  }

  String _state(OrganizationTask t) => widget.owner.organizationNeedsRenewal(t)
      ? '需重新发起'
      : switch (t.state) {
          OrganizationTaskState.active => '等待 Agent 提交',
          OrganizationTaskState.proposed => '方案待确认',
          OrganizationTaskState.confirmed => '已应用',
          OrganizationTaskState.rejected => '已拒绝',
          OrganizationTaskState.cancelled => '已取消',
          OrganizationTaskState.expired => '已到期',
          OrganizationTaskState.conflicted => '资料已变化，需重新整理',
        };
  @override
  Widget build(BuildContext context) => DesktopSubpage(
    title: 'Agent 整理',
    actions: [
      FilledButton.icon(
        onPressed: widget.itemIds.isEmpty || widget.itemIds.length > 200
            ? null
            : _start,
        icon: const Icon(Icons.auto_awesome_outlined, size: 17),
        label: const Text('创建整理任务'),
      ),
    ],
    body: Padding(
      padding: UiSpace.page,
      child: ListView(
        children: [
          Text(
            '为当前列表的 ${widget.itemIds.length} 条信息整理分类与标签。Agent 提交方案后，你一次确认整批调整。',
          ),
          if (widget.itemIds.length > 200)
            const QuietNotice('每次最多整理 200 条，请先在资料库筛选范围。'),
          const SizedBox(height: 20),
          if (widget.owner.organizationTasks.isEmpty)
            const EmptyWorkspace(
              icon: Icons.auto_awesome_outlined,
              title: '还没有整理任务',
              description: '先创建一次任务，再让对应聊天中的 Agent 领取并提交方案。',
            ),
          for (final task in widget.owner.organizationTasks.reversed)
            WorkspaceRecord(
              title: Text(task.purpose),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${task.chatLabel} · ${task.itemVersions.length} 条信息 · ${uiTime(task.createdAt)}',
                  ),
                  const SizedBox(height: 6),
                  StatusLabel(
                    _state(task),
                    active: task.state == OrganizationTaskState.confirmed,
                    attention: task.state == OrganizationTaskState.proposed,
                  ),
                  if (task.state == OrganizationTaskState.active &&
                      !widget.owner.organizationNeedsRenewal(task))
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('创建后，在对应 Agent 聊天中让它领取本次任务。'),
                    ),
                ],
              ),
              trailing: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (task.state == OrganizationTaskState.active &&
                      !widget.owner.organizationNeedsRenewal(task))
                    TextButton(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text:
                                '请领取信息授权中的整理任务 ${task.id}，根据本次获准的元数据整理分类与标签，并提交方案供我确认。',
                          ),
                        );
                      },
                      child: const Text('复制任务提示'),
                    ),
                  if (task.state == OrganizationTaskState.active)
                    TextButton(
                      onPressed: () => _cancel(task.id),
                      child: const Text('取消任务'),
                    ),
                  if (task.changes.isNotEmpty)
                    OutlinedButton(
                      onPressed: () => _view(task),
                      child: Text(
                        task.state == OrganizationTaskState.proposed
                            ? '查看整理方案'
                            : '查看结果',
                      ),
                    ),
                ],
              ),
            ),
          if (_error != null) QuietNotice(_error!, warning: true),
        ],
      ),
    ),
  );
}

class _StartOrganization extends StatefulWidget {
  const _StartOrganization({required this.owner, required this.itemIds});
  final OwnerAccess owner;
  final List<String> itemIds;
  @override
  State<_StartOrganization> createState() => _StartOrganizationState();
}

class _StartOrganizationState extends State<_StartOrganization> {
  late String? _agent = widget.owner.organizationAgents.lastOrNull?.id;
  final _purpose = TextEditingController(text: '整理资料的分类与标签');
  final _scopeScroll = ScrollController();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _purpose.dispose();
    _scopeScroll.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.owner.startOrganizationTask(
        _agent!,
        widget.itemIds,
        purpose: _purpose.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '未能创建任务，请检查聊天是否有效、资料是否已变化，然后重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('创建整理任务'),
    content: SizedBox(
      width: 600,
      height: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('本次范围：当前列表的 ${widget.itemIds.length} 条信息。'),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: Scrollbar(
                controller: _scopeScroll,
                thumbVisibility: true,
                child: ListView(
                  controller: _scopeScroll,
                  shrinkWrap: true,
                  children: [
                    for (final id in widget.itemIds)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          widget.owner.information
                                  .where((i) => i.id == id)
                                  .firstOrNull
                                  ?.name ??
                              '资料已删除',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '仅提供这些信息的标题、公开说明，以及现有分类和标签名称。不会提供字段值。元数据访问最长 30 分钟，提交方案后结束；确认方案后才调整分类。',
            ),
            const SizedBox(height: 18),
            if (widget.owner.organizationAgents.isEmpty)
              const QuietNotice(
                '还没有有效的 Agent 聊天。请先让 Agent 通过 CLI 建立会话，再回到这里创建任务。',
              )
            else
              DesktopSelect<String>(
                key: const ValueKey('organization-agent'),
                initialValue: _agent,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '接收任务的聊天（Agent 自述）',
                ),
                items: [
                  for (final a in widget.owner.organizationAgents)
                    DropdownMenuItem(value: a.id, child: Text(a.chatLabel)),
                ],
                onChanged: _saving ? null : (id) => setState(() => _agent = id),
              ),
            DesktopTextField(
              key: const ValueKey('organization-purpose'),
              controller: _purpose,
              enabled: !_saving,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '整理目的'),
            ),
            if (_error != null) QuietNotice(_error!, warning: true),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving || _agent == null ? null : _create,
        child: Text(_saving ? '正在创建…' : '创建任务'),
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
      height: 620,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                Text(
                  '${widget.task.chatLabel} · ${widget.task.changes.length} 条整理建议',
                ),
                const QuietNotice('只调整分类与标签，不修改内容，也不会增加已有授权的范围。'),
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
                              Text('建议分类：$proposedFolder'),
                              Text(
                                '建议标签：${proposedTags.isEmpty ? '无' : proposedTags}',
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
