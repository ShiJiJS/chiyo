import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

class UpdateProposalsList extends StatelessWidget {
  const UpdateProposalsList({
    super.key,
    required this.owner,
    required this.onChanged,
  });
  final OwnerAccess owner;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final proposal in owner.updateProposals.reversed)
        WorkspaceRecord(
          title: Text(
            '修改 ${owner.information.where((i) => i.id == proposal.input.itemId).firstOrNull?.name ?? '信息'}',
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('聊天  ${proposal.chatLabel}'),
              const SizedBox(height: 6),
              Text('基础版本 ${proposal.input.baseVersion}'),
              const SizedBox(height: 6),
              StatusLabel(
                switch (proposal.state) {
                  UpdateProposalState.pending => '待确认',
                  UpdateProposalState.confirmed => '已确认修改',
                  UpdateProposalState.rejected => '已拒绝',
                  UpdateProposalState.conflicted => '版本冲突，请提交新的提案',
                },
                attention: proposal.state == UpdateProposalState.pending,
                active: proposal.state == UpdateProposalState.confirmed,
              ),
            ],
          ),
          trailing: proposal.state == UpdateProposalState.pending
              ? OutlinedButton(
                  onPressed: () async {
                    await showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) =>
                          _ReviewUpdate(owner: owner, proposal: proposal),
                    );
                    onChanged();
                  },
                  child: const Text('查看修改差异'),
                )
              : null,
        ),
    ],
  );
}

class _ReviewUpdate extends StatefulWidget {
  const _ReviewUpdate({required this.owner, required this.proposal});
  final OwnerAccess owner;
  final UpdateProposal proposal;
  @override
  State<_ReviewUpdate> createState() => _ReviewUpdateState();
}

class _ReviewUpdateState extends State<_ReviewUpdate> {
  UpdatePreview? _preview;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    try {
      _preview = widget.owner.previewUpdate(widget.proposal.id);
    } on AccessFailure {
      _error = '资料版本已经变化或目标已不存在。请拒绝此提案，并让 Agent 根据当前版本重新提交。';
    }
  }

  Future<void> _decide(bool confirm) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (confirm) {
        await widget.owner.confirmUpdate(
          widget.proposal.id,
          widget.proposal.version,
        );
      } else {
        await widget.owner.rejectUpdate(
          widget.proposal.id,
          widget.proposal.version,
        );
      }
      if (mounted) Navigator.pop(context);
    } on AccessFailure catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _preview = null;
          _error = error.status == 'proposal_conflict'
              ? '资料版本已经变化，未应用修改。请关闭并查看状态，重新提交提案。'
              : '提案状态已经变化，未应用修改。请关闭后刷新。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，修改尚未确认。请检查存储后重试。';
        });
      }
    }
  }

  Widget _snapshot(String title, InformationItem item) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SectionHeading(title),
      Text(item.name, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      SelectableText(item.description),
      for (final f in item.fields)
        InformationValue(
          name: f.name,
          description: f.description,
          value: f.value,
        ),
    ],
  );
  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('确认修改差异'),
    content: SizedBox(
      width: 900,
      height: 650,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '普通值修正保留字段身份和已有授权；新增、替换含义使用新身份，需另行授权。移除字段后，旧授权立即停止读取该字段。确认不会为提交者增加读取权限。',
            ),
            for (final change in widget.proposal.input.changes)
              Text(switch (change.kind) {
                FieldChangeKind.correct => '操作：修正值（保留字段身份）',
                FieldChangeKind.add => '操作：新增字段（需要新授权）',
                FieldChangeKind.replace => '操作：替换业务含义（需要新授权）',
                FieldChangeKind.remove => '操作：移除字段（停止旧授权读取）',
              }),
            const Divider(),
            if (_preview != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _snapshot(
                      '修改前 · 版本 ${_preview!.before.version}',
                      _preview!.before,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(child: _snapshot('修改后', _preview!.after)),
                ],
              ),
            if (_error != null) QuietNotice(_error!, warning: true),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('暂不处理'),
      ),
      TextButton(
        onPressed: _saving ? null : () => _decide(false),
        child: const Text('拒绝修改'),
      ),
      FilledButton(
        onPressed: _saving || _preview == null ? null : () => _decide(true),
        child: const Text('确认这些修改'),
      ),
    ],
  );
}
