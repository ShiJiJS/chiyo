import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'update_proposals.dart';
import 'recycle.dart';
import 'ui.dart';

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

  String _names(ImportProposal proposal) {
    var names = proposal.state == ImportProposalState.pending
        ? proposal.items.map((i) => i.name).toList()
        : [
            for (final id in proposal.createdItemIds)
              for (final item in widget.owner.information.where(
                (i) => i.id == id,
              ))
                item.name,
          ];
    if (names.isEmpty) names = proposal.itemNames;
    return names.take(3).join(' · ') + (names.length > 3 ? ' 等' : '');
  }

  @override
  Widget build(BuildContext context) => ReadingWorkspace(
    child: ListView(
      padding: UiSpace.page,
      children: [
        const PageHeading('录入与变更提案', subtitle: '先查看和调整内容，确认后才会写入资料库。'),
        const QuietNotice('提交者由 Agent 自述。标题和说明对 Agent 可见，内容仍需另行授权。'),
        const SizedBox(height: 14),
        if (widget.owner.updateProposals.isNotEmpty ||
            widget.owner.deleteProposals.isNotEmpty)
          const SectionHeading('变更与删除'),
        DeleteProposalsList(
          owner: widget.owner,
          onChanged: () => setState(() {}),
        ),
        UpdateProposalsList(
          owner: widget.owner,
          onChanged: () => setState(() {}),
        ),
        if (widget.owner.importProposals.isEmpty &&
            widget.owner.updateProposals.isEmpty &&
            widget.owner.deleteProposals.isEmpty)
          const SizedBox(
            height: 320,
            child: EmptyWorkspace(
              icon: Icons.playlist_add_outlined,
              title: '暂无录入提案。',
              description: '让 Agent 整理信息并提交提案，你可以在这里批量预览与确认。',
            ),
          ),
        if (widget.owner.importProposals.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: SectionHeading('新增信息'),
          ),
        for (final proposal in widget.owner.importProposals.reversed)
          InkWell(
            onTap: () => _review(proposal),
            child: WorkspaceRecord(
              title: Text(
                '${proposal.agentName.isEmpty ? 'Agent（名称未记录）' : proposal.agentName} 提交了 ${proposal.itemCount} 条信息',
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    proposal.purpose.isEmpty
                        ? '用途：提交时未记录'
                        : '用途：${proposal.purpose}',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '聊天：${proposal.chatLabel} · ${uiTime(proposal.createdAt)}${proposal.fieldCount > 0 ? ' · ${proposal.fieldCount} 个字段' : ''}',
                  ),
                  if (_names(proposal).isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _names(proposal),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  StatusLabel(
                    switch (proposal.state) {
                      ImportProposalState.pending => '待确认',
                      ImportProposalState.confirmed => '已确认入库',
                      ImportProposalState.rejected => '已拒绝',
                    },
                    active: proposal.state == ImportProposalState.confirmed,
                    attention: proposal.state == ImportProposalState.pending,
                  ),
                ],
              ),
              trailing: OutlinedButton(
                onPressed: () => _review(proposal),
                child: Text(
                  proposal.state == ImportProposalState.pending
                      ? '查看提案'
                      : '查看详情',
                ),
              ),
            ),
          ),
      ],
    ),
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
  _DraftItem(this.original, OwnerAccess owner)
    : name = TextEditingController(text: original.name),
      description = TextEditingController(text: original.description),
      directoryId = original.directoryId,
      directorySuggestion = original.suggestedDirectory,
      suggestedTags = original.suggestedTags.toList(),
      tagIds = original.tagIds.toSet(),
      fields = original.fields.map(_DraftField.new).toList() {
    if (directoryId == null && directorySuggestion.trim().isNotEmpty) {
      final match = owner.directories
          .where(
            (d) =>
                d.parentId == null &&
                d.name.toLowerCase() ==
                    directorySuggestion.trim().toLowerCase(),
          )
          .firstOrNull;
      if (match != null) {
        directoryId = match.id;
        directorySuggestion = '';
      }
    }
    final names = List<String>.of(suggestedTags);
    suggestedTags.clear();
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      final match = owner.tags
          .where((t) => t.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (match != null) {
        tagIds.add(match.id);
      } else if (!suggestedTags.any(
        (n) => n.toLowerCase() == name.toLowerCase(),
      )) {
        suggestedTags.add(name);
      }
    }
  }
  final ImportItemInput original;
  final TextEditingController name, description;
  String? directoryId;
  String directorySuggestion;
  final List<String> suggestedTags;
  final Set<String> tagIds;
  final List<_DraftField> fields;
  ImportItemInput get input => ImportItemInput(
    name.text,
    description.text,
    fields.map((f) => f.input),
    directoryId: directoryId,
    tagIds: tagIds,
    suggestedDirectory: directorySuggestion,
    suggestedTags: suggestedTags,
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
  bool get _pending => widget.proposal.state == ImportProposalState.pending;
  late final List<_DraftItem> _items =
      (_pending
              ? widget.proposal.items
              : [
                  for (final id in widget.proposal.createdItemIds)
                    for (final item in widget.owner.information.where(
                      (i) => i.id == id,
                    ))
                      ImportItemInput(
                        item.name,
                        item.description,
                        item.fields.map(
                          (f) => FieldInput(
                            f.name,
                            f.description,
                            f.value,
                            kind: f.kind,
                          ),
                        ),
                        directoryId: item.directoryId,
                        tagIds: item.tagIds,
                      ),
                ])
          .map((input) => _DraftItem(input, widget.owner))
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

  Future<void> _edit(int index) async {
    final input = await showDialog<ImportItemInput>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _EditImportItem(owner: widget.owner, input: _items[index].input),
    );
    if (input != null && mounted) {
      setState(() {
        _items[index].dispose();
        _items[index] = _DraftItem(input, widget.owner);
      });
    }
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
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '未能保存，提案和更改已保留。请检查内容或存储后重试。';
        });
      }
    }
  }

  String _location(_DraftItem draft) {
    final folder = draft.directoryId != null
        ? directoryPath(widget.owner, draft.directoryId!)
        : draft.directorySuggestion;
    final tags = [
      ...draft.tagIds.map(
        (id) =>
            widget.owner.tags.where((t) => t.id == id).firstOrNull?.name ?? '',
      ),
      ...draft.suggestedTags,
    ].where((s) => s.isNotEmpty).toSet();
    return [
      folder.isEmpty ? '未分类' : folder,
      if (tags.isNotEmpty) tags.join('、'),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: Text(
      _pending
          ? '查看 ${_items.length} 条录入信息'
          : widget.proposal.state == ImportProposalState.confirmed
          ? '已入库资料详情'
          : '已拒绝提案',
    ),
    content: SizedBox(
      width: 860,
      height: 720,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                Text(
                  '提交 Agent（自述）：${widget.proposal.agentName.isEmpty ? '名称未记录' : widget.proposal.agentName}',
                ),
                Text(
                  '聊天：${widget.proposal.chatLabel}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (widget.proposal.purpose.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(widget.proposal.purpose),
                  ),
                QuietNotice(
                  _pending
                      ? '标题和说明对 Agent 可见，内容需授权。分类建议将随本次确认一起应用。'
                      : widget.proposal.state == ImportProposalState.confirmed
                      ? '只读查看当前资料。后续修改以资料库当前内容为准；已删除内容不会在提案中保留副本。'
                      : '这批提案未入库，拟录入内容已清理。',
                ),
                const SizedBox(height: 12),
                for (final (index, item) in _items.indexed)
                  Container(
                    padding: const EdgeInsets.all(20),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      border: Border.all(color: UiColors.line),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                item.name.text,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            if (_pending)
                              TextButton.icon(
                                key: ValueKey('edit-import-$index'),
                                onPressed: _saving ? null : () => _edit(index),
                                icon: const Icon(Icons.edit_outlined, size: 16),
                                label: const Text('编辑'),
                              ),
                          ],
                        ),
                        if (item.description.text.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(item.description.text),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            _location(item),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const Divider(),
                        for (final field in item.fields)
                          InformationValue(
                            name: field.name.text,
                            description: field.description.text,
                            value: field.value.text,
                          ),
                      ],
                    ),
                  ),
                if (widget.proposal.state == ImportProposalState.confirmed &&
                    _items.length < widget.proposal.itemCount)
                  const QuietNotice('部分资料已删除或不可用，不再显示其内容。'),
              ],
            ),
          ),
          if (_error != null) QuietNotice(_error!, warning: true),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(_pending ? '暂不处理' : '关闭'),
      ),
      if (_pending) ...[
        TextButton(
          onPressed: _saving ? null : () => _decide(false),
          child: const Text('拒绝整批'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => _decide(true),
          child: Text(_saving ? '正在入库…' : '确认全部入库'),
        ),
      ],
    ],
  );
}

class _EditImportItem extends StatefulWidget {
  const _EditImportItem({required this.owner, required this.input});
  final OwnerAccess owner;
  final ImportItemInput input;
  @override
  State<_EditImportItem> createState() => _EditImportItemState();
}

class _EditImportItemState extends State<_EditImportItem> {
  late final List<_DraftItem> _items = [
    widget.input,
  ].map((input) => _DraftItem(input, widget.owner)).toList();
  final bool _saving = false;
  String? _error;
  @override
  void dispose() {
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  void _save() {
    final input = _items.single.input;
    if (input.name.trim().isEmpty ||
        input.fields.any((f) => f.name.trim().isEmpty)) {
      setState(() => _error = '请填写信息名称和每项内容的名称。');
      return;
    }
    Navigator.pop(context, input);
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('编辑待录入信息'),
    content: SizedBox(
      width: 860,
      height: 720,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('保存更改后返回预览，确认整批入库后才会写入资料库。'),
            for (var i = 0; i < _items.length; i++) ...[
              const SizedBox(height: 20),
              EditorColumns(
                metadata: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionHeading('公开目录', detail: 'Agent 可见'),
                    if (_items[i].original.suggestedDirectory.isNotEmpty ||
                        _items[i].original.suggestedTags.isNotEmpty ||
                        _items[i].original.suggestedTemplate.isNotEmpty)
                      Text('已预选 Agent 建议，整批确认后保存。'),
                    DesktopTextField(
                      key: ValueKey('proposal-name-$i'),
                      controller: _items[i].name,
                      enabled: !_saving,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: '信息名称（公开）'),
                    ),
                    DesktopTextField(
                      key: ValueKey('proposal-description-$i'),
                      controller: _items[i].description,
                      enabled: !_saving,
                      maxLength: 2000,
                      decoration: const InputDecoration(labelText: '公开描述'),
                    ),
                    DesktopSelect<String>(
                      key: ValueKey('proposal-directory-$i'),
                      initialValue:
                          widget.owner.directories.any(
                            (d) => d.id == _items[i].directoryId,
                          )
                          ? _items[i].directoryId
                          : (_items[i].directorySuggestion.isNotEmpty
                                ? '__suggested__'
                                : null),
                      decoration: const InputDecoration(labelText: '分类'),
                      isExpanded: true,
                      items: [
                        if (_items[i].directorySuggestion.isNotEmpty)
                          DropdownMenuItem(
                            value: '__suggested__',
                            child: Text(
                              '${_items[i].directorySuggestion}（Agent 建议）',
                            ),
                          ),
                        const DropdownMenuItem(value: null, child: Text('未分类')),
                        for (final d in widget.owner.directories)
                          DropdownMenuItem(
                            value: d.id,
                            child: Text(directoryPath(widget.owner, d.id)),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (id) => setState(() {
                              if (id == '__suggested__') {
                                _items[i].directoryId = null;
                              } else {
                                _items[i].directoryId = id;
                                _items[i].directorySuggestion = '';
                              }
                            }),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final suggested in List<String>.of(
                          _items[i].suggestedTags,
                        ))
                          FilterChip(
                            label: Text('$suggested（建议）'),
                            selected: true,
                            onSelected: (_) => setState(
                              () => _items[i].suggestedTags.remove(suggested),
                            ),
                          ),
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
                                      _items[i].tagIds.add(
                                        widget.owner.tags[t].id,
                                      );
                                    } else {
                                      _items[i].tagIds.remove(
                                        widget.owner.tags[t].id,
                                      );
                                    }
                                  }),
                          ),
                      ],
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionHeading('信息字段', detail: '字段值需另行授权'),
                    for (var f = 0; f < _items[i].fields.length; f++) ...[
                      const SizedBox(height: 16),
                      DesktopTextField(
                        key: ValueKey('proposal-field-name-$i-$f'),
                        controller: _items[i].fields[f].name,
                        enabled: !_saving,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '字段名称（公开）',
                        ),
                      ),
                      DesktopTextField(
                        key: ValueKey('proposal-field-description-$i-$f'),
                        controller: _items[i].fields[f].description,
                        enabled: !_saving,
                        maxLength: 2000,
                        decoration: const InputDecoration(
                          labelText: '字段说明（公开）',
                        ),
                      ),
                      DesktopSelect<FieldKind>(
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
                            : (kind) => setState(
                                () => _items[i].fields[f].kind = kind!,
                              ),
                      ),
                      DesktopTextField(
                        key: ValueKey('proposal-value-$i-$f'),
                        controller: _items[i].fields[f].value,
                        enabled: !_saving,
                        maxLength: 64000,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '字段值（需要授权）',
                        ),
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
                ),
              ),
            ],
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
      FilledButton(onPressed: _save, child: const Text('保存更改')),
    ],
  );
}
