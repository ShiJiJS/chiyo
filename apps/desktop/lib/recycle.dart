import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

Future<void> confirmInformationDeletion(
  BuildContext context,
  OwnerAccess owner,
  InformationItem item, {
  String? fieldId,
  DeleteProposal? proposal,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DeleteInformation(
    owner: owner,
    item: item,
    fieldId: fieldId,
    proposal: proposal,
  ),
);

class _DeleteInformation extends StatefulWidget {
  const _DeleteInformation({
    required this.owner,
    required this.item,
    this.fieldId,
    this.proposal,
  });
  final OwnerAccess owner;
  final InformationItem item;
  final String? fieldId;
  final DeleteProposal? proposal;
  @override
  State<_DeleteInformation> createState() => _DeleteInformationState();
}

class _DeleteInformationState extends State<_DeleteInformation> {
  bool _saving = false;
  String? _error;
  Future<void> _decide(bool confirm) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final proposal = widget.proposal;
      if (proposal != null) {
        if (confirm) {
          await widget.owner.confirmDelete(proposal.id, proposal.version);
        } else {
          await widget.owner.rejectDelete(proposal.id, proposal.version);
        }
      } else if (confirm) {
        await widget.owner.deleteInformation(
          widget.item.id,
          widget.item.version,
          fieldId: widget.fieldId,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '资料或提案状态已经变化，或存储失败。请关闭后刷新检查；未成功删除的资料仍保留。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text(widget.fieldId == null ? '删除整条信息' : '删除选定字段'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.item.name),
            Text('版本 ${widget.item.version}'),
            if (widget.proposal != null)
              Text('提交会话：${widget.proposal!.chatLabel}'),
            const Text(
              '以下内容将进入回收站，默认保留 30 天。删除成功后，已有授权立即停止提供所删内容；恢复后需要重新批准访问。已披露内容和离线备份不会被收回。',
            ),
            for (final field in widget.item.fields.where(
              (f) => widget.fieldId == null || f.id == widget.fieldId,
            ))
              InformationValue(
                name: field.name,
                description: field.description,
                value: field.value,
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
      if (widget.proposal != null)
        TextButton(
          onPressed: _saving ? null : () => _decide(false),
          child: const Text('拒绝删除'),
        ),
      FilledButton(
        onPressed: _saving ? null : () => _decide(true),
        child: const Text('确认删除'),
      ),
    ],
  );
}

class RecyclePage extends StatefulWidget {
  const RecyclePage({super.key, required this.owner});
  final OwnerAccess owner;
  @override
  State<RecyclePage> createState() => _RecyclePageState();
}

class _RecyclePageState extends State<RecyclePage> {
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _clean();
  }

  Future<void> _clean() async {
    try {
      await widget.owner.purgeRecycle();
    } catch (_) {
      _error = '回收站清理失败，请检查存储后重试。';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _restore(RecycleEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => DesktopDialog(
        title: const Text('恢复信息'),
        content: Text(
          '恢复“${entry.snapshot!.name}”${entry.wholeItem ? '' : '中的选定字段'}。\n恢复后，Agent 需要重新批准才能读取，旧授权不会复活。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.owner.restoreRecycled(entry.id);
      _error = null;
    } catch (_) {
      _error = '无法恢复：内容可能已过保留期限、已恢复，或当前资料存在冲突。请检查后刷新。';
    }
    if (mounted) setState(() {});
  }

  Future<void> _view(RecycleEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => DesktopDialog(
      title: Text(entry.snapshot!.name),
      content: SizedBox(
        width: 700,
        height:
            entry.snapshot!.fields.length <= 2 &&
                entry.snapshot!.fields.every((f) => f.value.length < 200)
            ? 320
            : 500,
        child: ListView(
          children: [
            Text(
              '${entry.wholeItem ? '整条信息' : '选定字段'}\n删除于 ${uiTime(entry.deletedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const QuietNotice('回收站内容仅供你查看；恢复不会重新启用旧授权。'),
            for (final field in entry.snapshot!.fields)
              InformationValue(
                name: field.name,
                description: field.description,
                value: field.value,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => DesktopSubpage(
    title: '回收站',
    body: ListView(
      padding: UiSpace.page,
      children: [
        const QuietNotice('删除的内容保留 30 天，恢复后需重新授权。已导出的备份不会随清理删除。'),
        const SizedBox(height: 12),
        if (_error != null) QuietNotice(_error!, warning: true),
        if (_loading) const LinearProgressIndicator(),
        if (!_loading && widget.owner.recycleEntries.isEmpty)
          const EmptyWorkspace(
            icon: Icons.delete_outline,
            title: '回收站为空',
            description: '删除的资料会暂存在这里。',
          ),
        for (final entry in widget.owner.recycleEntries)
          WorkspaceRecord(
            title: Text(entry.snapshot!.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.wholeItem ? '整条信息' : '选定字段'}    ${entry.snapshot!.fields.length} 个字段',
                ),
                const SizedBox(height: 4),
                Text(
                  '删除于 ${uiTime(entry.deletedAt)}    保留至 ${uiTime(entry.expiresAt)}',
                ),
                const SizedBox(height: 4),
                Text(
                  entry.snapshot!.fields.take(3).map((f) => f.name).join('、'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            trailing: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => _view(entry),
                  child: const Text('查看内容'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _restore(entry),
                  icon: const Icon(Icons.restore_outlined, size: 17),
                  label: const Text('恢复'),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class DeleteProposalsList extends StatelessWidget {
  const DeleteProposalsList({
    super.key,
    required this.owner,
    required this.onChanged,
  });
  final OwnerAccess owner;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final p in owner.deleteProposals.reversed)
        WorkspaceRecord(
          title: Text(
            '删除 ${owner.information.where((i) => i.id == p.itemId).firstOrNull?.name ?? '信息'}',
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('聊天  ${p.chatLabel}'),
              const SizedBox(height: 6),
              Text(p.fieldId == null ? '整条信息' : '选定字段'),
              const SizedBox(height: 6),
              Text('提交时间  ${uiTime(p.createdAt)}'),
              const SizedBox(height: 6),
              StatusLabel(switch (p.state) {
                DeleteProposalState.pending => '待确认',
                DeleteProposalState.confirmed => '已确认删除',
                DeleteProposalState.rejected => '已拒绝',
                DeleteProposalState.conflicted => '目标版本已变化，请重新提交',
              }, attention: p.state == DeleteProposalState.pending),
            ],
          ),
          trailing: p.state != DeleteProposalState.pending
              ? null
              : OutlinedButton(
                  onPressed: () async {
                    try {
                      final item = owner.previewDelete(p.id);
                      if (context.mounted) {
                        await confirmInformationDeletion(
                          context,
                          owner,
                          item,
                          fieldId: p.fieldId,
                          proposal: p,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        await showDialog<void>(
                          context: context,
                          builder: (context) => DesktopDialog(
                            title: const Text('删除目标已变化'),
                            content: const Text(
                              '未删除任何资料。请拒绝此提案，让 Agent 根据当前目录重新提交。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'),
                              ),
                              TextButton(
                                onPressed: () async {
                                  try {
                                    await owner.rejectDelete(p.id, p.version);
                                    if (context.mounted) {
                                      Navigator.pop(context);
                                    }
                                  } catch (_) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('无法保存拒绝结果，请检查存储后重试。'),
                                        ),
                                      );
                                    }
                                  }
                                },
                                child: const Text('拒绝删除'),
                              ),
                            ],
                          ),
                        );
                      }
                    }
                    onChanged();
                  },
                  child: const Text('查看删除范围'),
                ),
        ),
    ],
  );
}
