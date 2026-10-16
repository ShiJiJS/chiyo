import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';

class ImportProposalsPage extends StatefulWidget {
  const ImportProposalsPage({super.key, required this.owner});
  final OwnerAccess owner;
  @override
  State<ImportProposalsPage> createState() => _ImportProposalsPageState();
}

class _ImportProposalsPageState extends State<ImportProposalsPage> {
  late final Timer _refresh;
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

  Future<void> _review(ImportProposal proposal) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReviewImport(owner: widget.owner, proposal: proposal),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('Agent 提交的内容需要你确认后才会入库。公开名称、描述和字段说明会出现在公开目录；字段值需另行授权。'),
      const SizedBox(height: 16),
      if (widget.owner.importProposals.isEmpty) const Text('暂无录入提案。'),
      for (final proposal in widget.owner.importProposals.reversed)
        Card(
          child: ListTile(
            title: Text('${proposal.chatLabel} · ${proposal.items.length} 条信息'),
            subtitle: Text(switch (proposal.state) {
              ImportProposalState.pending => '待确认',
              ImportProposalState.confirmed => '已确认入库',
              ImportProposalState.rejected => '已拒绝',
            }),
            trailing: proposal.state == ImportProposalState.pending
                ? FilledButton(
                    onPressed: () => _review(proposal),
                    child: const Text('预览并调整'),
                  )
                : null,
          ),
        ),
    ],
  );
}

class _DraftField {
  _DraftField(FieldInput f)
    : name = TextEditingController(text: f.name),
      description = TextEditingController(text: f.description),
      value = TextEditingController(text: f.value),
      kind = f.kind;
  final TextEditingController name, description, value;
  FieldKind kind;
  FieldInput get input =>
      FieldInput(name.text, description.text, value.text, kind: kind);
  void dispose() {
    name.dispose();
    description.dispose();
    value.dispose();
  }
}

class _DraftItem {
  _DraftItem(this.original)
    : name = TextEditingController(text: original.name),
      description = TextEditingController(text: original.description),
      directoryId = original.directoryId,
      tagIds = original.tagIds.toSet(),
      fields = original.fields.map(_DraftField.new).toList();
  final ImportItemInput original;
  final TextEditingController name, description;
  String? directoryId;
  final Set<String> tagIds;
  final List<_DraftField> fields;
  ImportItemInput get input => ImportItemInput(
    name.text,
    description.text,
    fields.map((f) => f.input),
    directoryId: directoryId,
    tagIds: tagIds,
  );
  void dispose() {
    name.dispose();
    description.dispose();
    for (final f in fields) {
      f.dispose();
    }
  }
}

class _ReviewImport extends StatefulWidget {
  const _ReviewImport({required this.owner, required this.proposal});
  final OwnerAccess owner;
  final ImportProposal proposal;
  @override
  State<_ReviewImport> createState() => _ReviewImportState();
}

class _ReviewImportState extends State<_ReviewImport> {
  late final List<_DraftItem> _items = widget.proposal.items
      .map(_DraftItem.new)
      .toList();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _decide(bool confirm) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (confirm) {
        await widget.owner.confirmImport(
          widget.proposal.id,
          widget.proposal.version,
          _items.map((i) => i.input).toList(),
        );
      } else {
        await widget.owner.rejectImport(
          widget.proposal.id,
          widget.proposal.version,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '未能处理提案，请检查字段和分类，或关闭后刷新查看当前状态。';
        });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('确认 ${_items.length} 条新增信息'),
    content: SizedBox(
      width: 760,
      height: 720,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('请检查公开描述是否含隐私。入库不会给提交提案的 Agent 自动授权，也不会覆盖已有信息。'),
            for (var i = 0; i < _items.length; i++) ...[
              const Divider(height: 32),
              Text('信息 ${i + 1}'),
              if (_items[i].original.suggestedDirectory.isNotEmpty ||
                  _items[i].original.suggestedTags.isNotEmpty ||
                  _items[i].original.suggestedTemplate.isNotEmpty)
                Text(
                  'Agent 建议：目录 ${_items[i].original.suggestedDirectory}；标签 ${_items[i].original.suggestedTags.join('、')}；模板 ${_items[i].original.suggestedTemplate}（仅作参考，不自动创建或套用）',
                ),
              TextField(
                key: ValueKey('proposal-name-$i'),
                controller: _items[i].name,
                enabled: !_saving,
                maxLength: 200,
                decoration: const InputDecoration(labelText: '信息名称（公开）'),
              ),
              TextField(
                key: ValueKey('proposal-description-$i'),
                controller: _items[i].description,
                enabled: !_saving,
                maxLength: 2000,
                decoration: const InputDecoration(labelText: '公开描述'),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('proposal-directory-$i'),
                initialValue:
                    widget.owner.directories.any(
                      (d) => d.id == _items[i].directoryId,
                    )
                    ? _items[i].directoryId
                    : null,
                decoration: const InputDecoration(labelText: '目录（本人整理）'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('未分类')),
                  for (final d in widget.owner.directories)
                    DropdownMenuItem(
                      value: d.id,
                      child: Text(directoryPath(widget.owner, d.id)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (id) => setState(() => _items[i].directoryId = id),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (var t = 0; t < widget.owner.tags.length; t++)
                    FilterChip(
                      key: ValueKey('proposal-tag-$i-$t'),
                      label: Text(widget.owner.tags[t].name),
                      selected: _items[i].tagIds.contains(
                        widget.owner.tags[t].id,
                      ),
                      onSelected: _saving
                          ? null
                          : (selected) => setState(() {
                              if (selected) {
                                _items[i].tagIds.add(widget.owner.tags[t].id);
                              } else {
                                _items[i].tagIds.remove(
                                  widget.owner.tags[t].id,
                                );
                              }
                            }),
                    ),
                ],
              ),
              for (var f = 0; f < _items[i].fields.length; f++) ...[
                TextField(
                  key: ValueKey('proposal-field-name-$i-$f'),
                  controller: _items[i].fields[f].name,
                  enabled: !_saving,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '字段名称（公开）'),
                ),
                TextField(
                  key: ValueKey('proposal-field-description-$i-$f'),
                  controller: _items[i].fields[f].description,
                  enabled: !_saving,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '字段说明（公开）'),
                ),
                DropdownButtonFormField<FieldKind>(
                  initialValue: _items[i].fields[f].kind,
                  decoration: const InputDecoration(labelText: '字段类型'),
                  items: const [
                    DropdownMenuItem(
                      value: FieldKind.structured,
                      child: Text('结构化字段'),
                    ),
                    DropdownMenuItem(
                      value: FieldKind.textNote,
                      child: Text('文本说明'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (kind) =>
                            setState(() => _items[i].fields[f].kind = kind!),
                ),
                TextField(
                  key: ValueKey('proposal-value-$i-$f'),
                  controller: _items[i].fields[f].value,
                  enabled: !_saving,
                  maxLength: 64000,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '字段值（需要授权）'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _saving || _items[i].fields.length <= 1
                        ? null
                        : () => setState(() {
                            _items[i].fields.removeAt(f).dispose();
                          }),
                    child: const Text('移除此字段'),
                  ),
                ),
              ],
              TextButton(
                onPressed: _saving || _items[i].fields.length >= 50
                    ? null
                    : () => setState(
                        () => _items[i].fields.add(
                          _DraftField(const FieldInput('', '', '')),
                        ),
                      ),
                child: const Text('添加字段'),
              ),
            ],
            if (_error != null) Text(_error!),
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
        child: const Text('拒绝整批'),
      ),
      FilledButton(
        onPressed: _saving ? null : () => _decide(true),
        child: const Text('确认全部入库'),
      ),
    ],
  );
}
