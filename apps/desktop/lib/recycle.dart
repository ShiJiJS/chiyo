import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'organization.dart';
import 'information_field_preview.dart';

Future<void> confirmInformationDeletion(
  BuildContext context,
  OwnerAccess owner,
  InformationItem item, {
  String? fieldId,
  DeleteProposal? proposal,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierColor: const Color(0x4f241b27),
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
  Widget build(BuildContext context) => PrototypeDialog(
    title: widget.fieldId == null ? '删除整条信息' : '删除选定字段',
    onClose: _saving ? null : () => Navigator.pop(context),
    body: SizedBox(
      child: SingleChildScrollView(
        primary: false,
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
              InformationFieldPreview(owner: widget.owner, field: field),
            if (_error != null) QuietNotice(_error!, warning: true),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        style: prototypeSecondary(context),
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      if (widget.proposal != null)
        TextButton(
          onPressed: _saving ? null : () => _decide(false),
          child: const Text('拒绝删除'),
        ),
      FilledButton(
        style: prototypePrimary(context),
        onPressed: _saving ? null : () => _decide(true),
        child: const Text('确认删除'),
      ),
    ],
  );
}

class RecyclePage extends StatefulWidget {
  const RecyclePage({super.key, required this.owner, this.asDialog = false});
  final OwnerAccess owner;
  final bool asDialog;
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
      barrierColor: const Color(0x4f241b27),
      builder: (context) => PrototypeDialog(
        title: '恢复信息',
        onClose: () => Navigator.pop(context, false),
        body: Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Text(
            '恢复“${entry.snapshot!.name}”${entry.wholeItem ? '' : '中的选定字段'}。\n恢复后，Agent 需要重新批准才能读取，旧授权不会复活。'
            '${organizationRecoveryNotice(widget.owner, entry.snapshot!) == null ? '' : '\n${organizationRecoveryNotice(widget.owner, entry.snapshot!)}'}',
          ),
        ),
        actions: [
          TextButton(
            style: prototypeSecondary(context),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: prototypePrimary(context),
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
    barrierColor: const Color(0x4f241b27),
    builder: (context) => PrototypeDialog(
      flow: true,
      title: entry.snapshot!.name,
      onClose: () => Navigator.pop(context),
      body: SizedBox(
        width: 700,
        height:
            entry.snapshot!.fields.length <= 2 &&
                entry.snapshot!.fields.every(
                  (f) => f.kind == FieldKind.file || f.value.length < 200,
                )
            ? 360
            : 500,
        child: ListView(
          primary: false,
          children: [
            Text(
              '${entry.wholeItem ? '整条信息' : '选定字段'}\n删除于 ${uiTime(entry.deletedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const QuietNotice('回收站内容仅供你查看；恢复不会重新启用旧授权。'),
            for (final field in entry.snapshot!.fields)
              InformationFieldPreview(owner: widget.owner, field: field),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: prototypeSecondary(context),
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => _surface(
    ListView(
      primary: false,
      shrinkWrap: widget.asDialog,
      physics: widget.asDialog ? const NeverScrollableScrollPhysics() : null,
      padding: widget.asDialog ? EdgeInsets.zero : UiSpace.page,
      children: [
        Text(
          '删除的内容保留 30 天，恢复后需重新授权。已导出的备份不会随清理删除。',
          style: prototypeText(context, 14, height: 1.85),
        ),
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
                if (entry.snapshot!.fields.any((f) => f.kind == FieldKind.file))
                  const Text('包含文件及其保留版本'),
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
  Widget _surface(Widget body) => widget.asDialog
      ? PrototypeDialog(
          flow: true,
          scrollGutter: 0,
          title: '信息回收站',
          onClose: () => Navigator.pop(context),
          body: _dialogBody(),
        )
      : DesktopSubpage(title: '回收站', body: body);
  Widget _dialogBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: prototypeCh(context, 14, 48)),
          child: Text(
            '保留 30 天。恢复信息不会恢复旧授权；关联凭据仍独立保存。',
            style: prototypeText(
              context,
              14,
              height: 1.85,
              color: UiPalette.of(context).muted,
            ),
          ),
        ),
      ),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _error!,
            style: prototypeText(
              context,
              13,
              color: UiPalette.of(context).danger,
            ),
          ),
        ),
      if (!_loading && widget.owner.recycleEntries.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: prototypeCh(context, 14, 48),
              ),
              child: Text(
                '回收站为空。信息详情中的「移入回收站」会将信息保留在这里。',
                style: prototypeText(context, 14, height: 1.85),
              ),
            ),
          ),
        ),
      for (final entry in widget.owner.recycleEntries)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 23),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: UiPalette.of(context).line),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.snapshot!.name,
                      style: prototypeText(
                        context,
                        14,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      directoryPath(widget.owner, entry.snapshot!.directoryId),
                      style: prototypeText(
                        context,
                        12,
                        color: UiPalette.of(context).muted,
                      ),
                    ),
                    if (entry.snapshot!.fields.any(
                      (f) => f.kind == FieldKind.file,
                    ))
                      Text(
                        '包含文件及其保留版本',
                        style: prototypeText(
                          context,
                          13,
                          height: 1.8,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      '${entry.wholeItem ? '整条信息' : '选定字段'} · ${entry.snapshot!.fields.length} 个字段 · 保留至 ${uiTime(entry.expiresAt)}',
                      style: prototypeText(
                        context,
                        12,
                        color: UiPalette.of(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                style: prototypeButton(
                  context,
                  size: 12,
                  foreground: UiPalette.of(context).accent,
                ),
                onPressed: () => _view(entry),
                child: const Text('查看内容'),
              ),
              const SizedBox(width: 12),
              TextButton(
                style: prototypeSecondary(context),
                onPressed: () => _restore(entry),
                child: const Text('恢复信息'),
              ),
            ],
          ),
        ),
    ],
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
