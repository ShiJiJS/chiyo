import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'information_editor.dart';
import 'organization.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'proposal_queue.dart';
import 'ui_palette.dart';
import 'information_field_preview.dart';

String _fieldKind(FieldKind kind) => switch (kind) {
  FieldKind.structured => '结构化字段',
  FieldKind.textNote => '受控说明',
  FieldKind.file => '文件',
};

class ImportProposalsPage extends StatefulWidget {
  const ImportProposalsPage({
    super.key,
    required this.owner,
    this.initialProposalId,
    this.onOpenInformation,
    this.onGoToLibrary,
    this.onOpenOrganizationGrant,
  });
  final OwnerAccess owner;
  final String? initialProposalId;
  final ValueChanged<String>? onOpenInformation;
  final VoidCallback? onGoToLibrary;
  final ValueChanged<String>? onOpenOrganizationGrant;
  @override
  State<ImportProposalsPage> createState() => _ImportProposalsPageState();
}

class _ImportProposalsPageState extends State<ImportProposalsPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _confirmFocus = FocusNode(),
      _rejectFocus = FocusNode(),
      _queueFocus = FocusNode(),
      _updateFocus = FocusNode();
  final _importFocus = <String, FocusNode>{};
  final _documentScroll = ScrollController();
  final _positions = <String, double>{};
  final _drafts = <String, List<ImportItemInput>>{};
  final _updates = <String, InformationEditorDraft>{};
  late final Timer _refresh;
  late String? _focused = widget.initialProposalId;
  bool _externalFocus = false;
  ProposalFilter _filter = ProposalFilter.pending;
  int _offset = 0;
  bool _busy = false;
  final _errors = <String, String>{};
  OwnerAccess get owner => widget.owner;
  UiPalette get p => UiPalette.of(context);
  @override
  void initState() {
    super.initState();
    if (widget.initialProposalId case final id?) _locate(id);
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant ImportProposalsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProposalId != oldWidget.initialProposalId &&
        widget.initialProposalId != null) {
      _locate(widget.initialProposalId!);
    }
  }

  void _locate(String id) {
    _focused = id;
    _externalFocus = true;
    _search.clear();
    _offset = 0;
    _filter = ProposalFilter.pending;
    try {
      final entry = owner
          .queryProposals(search: id, filter: ProposalFilter.all)
          .entries
          .where((entry) => entry.id == id)
          .firstOrNull;
      if (entry == null || !entry.pending) _filter = ProposalFilter.all;
    } catch (_) {
      /* Query failure is displayed by the normal build boundary. */
    }
  }

  @override
  void dispose() {
    _refresh.cancel();
    _search.dispose();
    _searchFocus.dispose();
    for (final node in [
      _confirmFocus,
      _rejectFocus,
      _queueFocus,
      _updateFocus,
      ..._importFocus.values,
    ]) {
      node.dispose();
    }
    _documentScroll.dispose();
    super.dispose();
  }

  Text t(
    String value,
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
    String? family,
    double height = 1.5,
  }) => Text(
    value,
    style: prototypeText(
      context,
      size,
      color: color,
      weight: weight,
      family: family,
      height: height,
    ),
  );
  void _select(String? id) {
    _externalFocus = false;
    if (_focused != null && _documentScroll.hasClients) {
      _positions[_focused!] = _documentScroll.offset;
    }
    setState(() => _focused = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_documentScroll.hasClients) {
        _documentScroll.jumpTo(
          (_positions[id] ?? 0).clamp(
            0,
            _documentScroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  void _queryChanged() {
    _offset = 0;
    _select(null);
  }

  List<ImportItemInput> _inputs(ProposalEntry entry) => _drafts.putIfAbsent(
    entry.id,
    () => List.of(
      owner.importProposals
          .firstWhere((proposal) => proposal.id == entry.id)
          .items,
    ),
  );
  Future<void> _editImport(ProposalEntry entry, int index) async {
    final focus = _importFocus.putIfAbsent('${entry.id}:$index', FocusNode.new)
      ..requestFocus();
    final input = _inputs(entry)[index];
    final draft = InformationEditorDraft(
      name: input.name,
      description: input.description,
      directoryId: input.directoryId,
      tagIds: input.tagIds,
      suggestedDirectory: input.suggestedDirectory,
      suggestedTags: input.suggestedTags,
      fields: input.fields
          .map(
            (field) => EditableInformationField(
              name: field.name,
              description: field.description,
              value: field.value,
              kind: field.kind,
            ),
          )
          .toList(),
    );
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => InformationEditor(
        title: '调整提案内容',
        saveLabel: '保存提案调整',
        draft: draft,
        directories: owner.directories,
        tags: owner.tags,
        onSave: (edited) async {
          final current = owner.importProposals
              .where((proposal) => proposal.id == entry.id)
              .firstOrNull;
          if (current?.state != ImportProposalState.pending ||
              current!.version != entry.version) {
            throw const AccessFailure('information_conflict');
          }
          setState(
            () => _inputs(entry)[index] = ImportItemInput(
              edited.name,
              edited.description,
              edited.fields.map((field) => field.input),
              directoryId: edited.directoryId,
              tagIds: edited.tagIds,
              suggestedDirectory: edited.suggestedDirectory,
              suggestedTags: edited.suggestedTags,
              suggestedTemplate: input.suggestedTemplate,
            ),
          );
        },
      ),
    );
    if (mounted) focus.requestFocus();
  }

  Future<void> _decide(ProposalEntry entry, bool confirm) async {
    if (_busy) return;
    final origin = confirm ? _confirmFocus : _rejectFocus;
    origin.requestFocus();
    final accepted = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => PrototypeDialog(
        title: confirm ? '确认这批变更' : '拒绝这次提案',
        actionDivider: false,
        onClose: () => Navigator.pop(dialogContext, false),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            t(
              confirm
                  ? '${entry.chatLabel}：${entry.count} 条信息。确认后将应用上方核对的全部内容。'
                  : '拒绝后，这次提案不会改变信息库。',
              14,
              height: 1.9,
              color: p.muted,
            ),
            if (confirm) ...[
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 19,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: p.rail,
                  border: Border.all(color: p.line),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: PrototypeIcon(
                        PrototypeIconGlyph.file,
                        color: p.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: t(
                        entry.kind == ProposalKind.addition
                            ? '新增信息按提案中的目录和标签入库。'
                            : entry.kind == ProposalKind.deletion
                            ? '目标信息将移入回收站。'
                            : '仅修改差异表中列出的字段。',
                        13,
                        height: 1.9,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            style: prototypeSecondary(context),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('返回核对'),
          ),
          TextButton(
            key: const ValueKey('confirm-proposal-decision'),
            style: prototypePrimary(context).copyWith(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 21, vertical: 11),
              ),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirm ? '确认' : '确认拒绝'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accepted != true) {
      origin.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _errors.remove(entry.id);
    });
    try {
      switch (entry.kind) {
        case ProposalKind.addition:
          if (confirm) {
            await owner.confirmImport(entry.id, entry.version, _inputs(entry));
          } else {
            await owner.rejectImport(entry.id, entry.version);
          }
        case ProposalKind.modification:
          if (confirm) {
            await owner.confirmUpdate(
              entry.id,
              entry.version,
              review: _review(entry),
            );
          } else {
            await owner.rejectUpdate(entry.id, entry.version);
          }
        case ProposalKind.deletion:
          if (confirm) {
            await owner.confirmDelete(entry.id, entry.version);
          } else {
            await owner.rejectDelete(entry.id, entry.version);
          }
        case ProposalKind.organization:
          if (confirm) {
            await owner.confirmOrganization(entry.id);
          } else {
            await owner.rejectOrganization(entry.id);
          }
      }
      _drafts.remove(entry.id);
      _updates.remove(entry.id);
      if (mounted) {
        setState(() {
          _filter = ProposalFilter.handled;
          _focused = entry.id;
          _offset = 0;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _queueFocus.requestFocus();
        });
      }
    } on AccessFailure catch (error) {
      if (mounted) {
        setState(() {
          final changed = [
            'proposal_conflict',
            'proposal_changed',
            'organization_conflict',
          ].contains(error.status);
          if (changed) {
            _filter = ProposalFilter.all;
            _search.clear();
            _focused = entry.id;
            _offset = 0;
          }
          if (changed) {
            _errors[entry.id] =
                '当前信息或提案状态已变化，未覆盖当前内容。请核对当前信息，让 Agent 根据最新版本重新提交。';
          }
        });
        if (![
          'proposal_conflict',
          'proposal_changed',
          'organization_conflict',
        ].contains(error.status)) {
          await _showBatchFailure('未能确认整批内容。草稿已保留，请检查输入和服务状态后重试。');
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ([
                      'proposal_conflict',
                      'proposal_changed',
                      'organization_conflict',
                    ].contains(error.status)
                    ? _queueFocus
                    : origin)
                .requestFocus();
          }
        });
      }
    } catch (_) {
      if (mounted) {
        await _showBatchFailure('整批确认失败，信息库未改变。提案和调整内容已保留。');
        if (mounted) origin.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showBatchFailure(String message) async {
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => PrototypeDialog(
        flow: true,
        title: '',
        bottomPadding: 28,
        bodyBottomPadding: 0,
        onClose: () => Navigator.pop(dialogContext),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: prototypeCh(context, 14, 48),
              ),
              margin: const EdgeInsets.symmetric(vertical: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.rail,
                border: Border.all(color: p.line),
              ),
              child: t(message, 14, color: p.muted, height: 1.85),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 12),
              child: t('未应用这批变更', 16, weight: FontWeight.w700),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: prototypeCh(context, 14, 48),
              ),
              child: t('调整内容仍保留，可以返回核对后重试。', 14, height: 1.85, color: p.muted),
            ),
            const SizedBox(height: 15),
            TextButton(
              style: prototypeSecondary(context),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回核对'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (owner.serviceAvailable) {
      final pendingImports = owner.importProposals
          .where((p) => p.state == ImportProposalState.pending)
          .map((p) => p.id)
          .toSet();
      final pendingUpdates = owner.updateProposals
          .where((p) => p.state == UpdateProposalState.pending)
          .map((p) => p.id)
          .toSet();
      _drafts.removeWhere((id, _) => !pendingImports.contains(id));
      _updates.removeWhere((id, _) => !pendingUpdates.contains(id));
    } else {
      _drafts.clear();
      _updates.clear();
    }
    ProposalPage page;
    String? queryError;
    try {
      page = owner.queryProposals(
        search: _search.text,
        filter: _filter,
        offset: _offset,
        focusProposalId: _focused,
      );
      if (_externalFocus &&
          !page.entries.any((entry) => entry.id == _focused)) {
        final all = owner.queryProposals(
          filter: ProposalFilter.all,
          focusProposalId: _focused,
        );
        if (all.entries.any((entry) => entry.id == _focused)) {
          _filter = ProposalFilter.all;
          page = all;
        }
      }
    } catch (_) {
      queryError = '提案查询失败，请调整条件或检查服务状态。';
      page = ProposalPage(
        const [],
        total: 0,
        allCount: 0,
        pendingCount: 0,
        offset: 0,
        limit: 8,
      );
    }
    _offset = page.offset;
    if (!_externalFocus && !page.entries.any((entry) => entry.id == _focused)) {
      _focused = page.entries.firstOrNull?.id;
    }
    final selected = page.entries
        .where((entry) => entry.id == _focused)
        .firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth
            .clamp(900, double.infinity)
            .toDouble();
        final surface = SizedBox(
          width: width,
          height: constraints.maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 310,
                child: ProposalQueue(
                  page: page,
                  focused: _focused,
                  search: _search,
                  searchFocus: _searchFocus,
                  selectedFocus: _queueFocus,
                  queryFailed: queryError != null,
                  filter: _filter,
                  onSearch: (_) => _queryChanged(),
                  onFilter: (filter) {
                    _filter = filter;
                    _queryChanged();
                  },
                  onPage: (offset) {
                    _offset = offset;
                    _select(null);
                  },
                  onSelect: _select,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 23, 28, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 34,
                        child: Row(
                          children: [
                            t('录入提案', 12, color: p.muted),
                            const SizedBox(width: 10),
                            const PrototypeIcon(
                              PrototypeIconGlyph.chev,
                              size: 13,
                            ),
                            const SizedBox(width: 10),
                            t(
                              selected?.kind == ProposalKind.organization
                                  ? '整理结果'
                                  : '内容核对',
                              12,
                              weight: FontWeight.w500,
                            ),
                            const SizedBox(width: 20),
                            if (selected != null)
                              Expanded(
                                child: Text(
                                  selected.id,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: prototypeText(
                                    context,
                                    12,
                                    color: p.muted,
                                    family: 'Consolas',
                                  ),
                                ),
                              ),
                            if (selected == null) const Spacer(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: selected == null
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    PrototypeIcon(
                                      PrototypeIconGlyph.search,
                                      size: 24,
                                      color: p.muted,
                                    ),
                                    const SizedBox(height: 14),
                                    t(
                                      queryError ??
                                          (_externalFocus
                                              ? '该提案已不存在。请从左侧选择其他提案。'
                                              : '没有匹配的内容'),
                                      18,
                                    ),
                                    if (queryError == null) ...[
                                      const SizedBox(height: 12),
                                      t(
                                        '调整左侧搜索或筛选后，继续查看详情。',
                                        14,
                                        color: p.muted,
                                      ),
                                    ],
                                  ],
                                ),
                              )
                            : _document(selected),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        return width > constraints.maxWidth
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: surface,
              )
            : surface;
      },
    );
  }

  Widget _document(ProposalEntry entry) => Container(
    key: const ValueKey('proposal-document'),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: p.paper,
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(7),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0632202d),
          offset: Offset(0, 3),
          blurRadius: 8,
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: _documentScroll,
            padding: const EdgeInsets.fromLTRB(34, 28, 42, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: entry.pending ? p.statusAttention : p.muted,
                          width: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    t(
                      entry.stateLabel,
                      12,
                      color: entry.pending ? p.statusAttention : p.muted,
                    ),
                    const SizedBox(width: 12),
                    t(
                      '${entry.kindLabel} · ${entry.count} 条信息${entry.changeCount == 0 ? '' : ' · ${entry.changeCount} 处修改'}',
                      12,
                      color: p.muted,
                    ),
                    const Spacer(),
                    t('提交于 ${_time(entry.createdAt)}', 12, color: p.muted),
                  ],
                ),
                const SizedBox(height: 13),
                t(
                  entry.chatLabel,
                  29,
                  family: 'SimSun',
                  weight: FontWeight.w500,
                ),
                // SimSun's 43.5px CSS line box is rounded to 44px by Flutter.
                const SizedBox(height: 15.5),
                Row(
                  children: [
                    Container(
                      width:
                          28 * MediaQuery.textScalerOf(context).scale(16) / 16,
                      height:
                          28 * MediaQuery.textScalerOf(context).scale(16) / 16,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: p.selected,
                        border: Border.all(color: p.line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: t(
                        entry.agentName == 'Codex' ? 'C' : 'A',
                        16,
                        family: 'Georgia',
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    t(
                      entry.agentName.isEmpty ? 'Agent' : entry.agentName,
                      13,
                      weight: FontWeight.w700,
                    ),
                    const SizedBox(width: 8),
                    t('当前聊天', 12, color: p.muted),
                  ],
                ),
                const SizedBox(height: 17),
                t(
                  entry.purpose.isEmpty ? '请核对下面的实际内容。' : entry.purpose,
                  14,
                  height: 1.9,
                  color: p.muted,
                ),
                const SizedBox(height: 8),
                t(
                  '提交方与用途由 Agent 自述；请核对下面的实际内容。',
                  12,
                  height: 1.9,
                  color: p.muted,
                ),
                if (_errors[entry.id] != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: t(
                      _errors[entry.id]!,
                      13,
                      color: p.danger,
                      height: 1.8,
                    ),
                  ),
                if (entry.kind == ProposalKind.organization)
                  _organizationBody(entry)
                else if (entry.pending && entry.kind == ProposalKind.addition)
                  _newItems(entry)
                else if (entry.pending &&
                    entry.kind == ProposalKind.modification)
                  _updateBody(entry)
                else if (entry.pending && entry.kind == ProposalKind.deletion)
                  _deleteBody(entry)
                else if (!entry.pending)
                  _receipt(entry)
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 21),
                    child: t('请核对目标信息与当前版本。', 14),
                  ),
              ],
            ),
          ),
        ),
        _actions(entry),
      ],
    ),
  );
  Widget _heading(String title, String caption) => Container(
    margin: const EdgeInsets.only(top: 21),
    padding: const EdgeInsets.only(top: 18),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: p.line)),
    ),
    child: Row(
      children: [
        Expanded(child: t(title, 17, weight: FontWeight.w700)),
        const SizedBox(width: 20),
        t(caption, 12, color: p.muted),
      ],
    ),
  );
  InformationItem? _metadataVersion(String id, int version) =>
      owner.information
          .where((item) => item.id == id && item.version == version)
          .firstOrNull ??
      owner.informationRevisions
          .where(
            (revision) =>
                revision.item.id == id && revision.item.version == version,
          )
          .firstOrNull
          ?.item;
  Widget _organizationBody(ProposalEntry entry) {
    final task = owner.organizationTasks.firstWhere(
      (task) => task.id == entry.id,
    );
    final state = owner.organizationState(task);
    final completed = state == OrganizationTaskState.confirmed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 22),
          padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 16),
          decoration: BoxDecoration(
            color: p.rail,
            border: Border.all(color: p.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrototypeIcon(PrototypeIconGlyph.shield, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    t(
                      completed && task.changes.isNotEmpty
                          ? '已在授权范围内完成整理'
                          : state == OrganizationTaskState.proposed
                          ? '旧版整理方案尚未确认'
                          : entry.stateLabel,
                      13,
                      weight: FontWeight.w700,
                      height: 21 / 13,
                    ),
                    const SizedBox(height: 5),
                    t(
                      state == OrganizationTaskState.proposed
                          ? '此方案沿用提交时的旧版审阅流程，确认前不会应用。'
                          : completed && task.changes.isEmpty
                          ? '没有分类或标签变化。已完成本次整理，整理能力已经结束。'
                          : '仅调整目录和标签，未读取或修改字段值。这里展示执行结果，无需再次确认。',
                      13,
                      height: 1.9,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (completed && task.changes.isNotEmpty) ...[
          _heading('整理明细', '${task.changes.length} 条信息'),
          Container(
            padding: const EdgeInsets.only(top: 13, bottom: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Row(
              children: [
                SizedBox(width: 140, child: t('信息', 12, color: p.muted)),
                const SizedBox(width: 18),
                Expanded(child: t('变更前', 12, color: p.muted)),
                const SizedBox(width: 18),
                Expanded(child: t('变更后', 12, color: p.muted)),
              ],
            ),
          ),
          for (final change in task.changes)
            Builder(
              builder: (context) {
                final before = _metadataVersion(
                  change.itemId,
                  change.baseVersion,
                );
                final after = _metadataVersion(
                  change.itemId,
                  change.baseVersion + 1,
                );
                Widget metadata(
                  InformationItem? item, {
                  bool highlight = false,
                }) => item == null
                    ? t('当时分类快照已不可用', 13, color: p.muted)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          t(
                            directoryPath(owner, item.directoryId),
                            13,
                            color:
                                highlight &&
                                    before?.directoryId != item.directoryId
                                ? p.strong
                                : null,
                            weight:
                                highlight &&
                                    before?.directoryId != item.directoryId
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          const SizedBox(height: 5),
                          t(
                            '标签：${owner.tags.where((tag) => item.tagIds.contains(tag.id)).map((tag) => tag.name).join('、')}',
                            12,
                            color:
                                highlight &&
                                    (before == null ||
                                        before.tagIds.length !=
                                            item.tagIds.length ||
                                        before.tagIds.any(
                                          (id) => !item.tagIds.contains(id),
                                        ))
                                ? p.strong
                                : p.muted,
                            weight:
                                highlight &&
                                    (before == null ||
                                        before.tagIds.length !=
                                            item.tagIds.length ||
                                        before.tagIds.any(
                                          (id) => !item.tagIds.contains(id),
                                        ))
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ],
                      );
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.line)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 140,
                        child: t(
                          after?.name ?? before?.name ?? '信息 ${change.itemId}',
                          13,
                          weight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(child: metadata(before)),
                      const SizedBox(width: 18),
                      Expanded(child: metadata(after, highlight: true)),
                    ],
                  ),
                );
              },
            ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TextButton(
              style: prototypeButton(
                context,
                size: 13,
                foreground: p.strong,
                padding: const EdgeInsets.all(8),
              ),
              onPressed: () => _openOrganizationGrant(entry),
              child: const Text('查看本次整理授权 →'),
            ),
          ),
        ),
      ],
    );
  }

  void _openOrganizationGrant(ProposalEntry entry) {
    if (widget.onOpenOrganizationGrant != null) {
      widget.onOpenOrganizationGrant!(entry.id);
      return;
    }
    final task = owner.organizationTasks.firstWhere(
      (task) => task.id == entry.id,
    );
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (context) => PrototypeDialog(
        title: '本次整理记录',
        onClose: () => Navigator.pop(context),
        body: Text(
          '记录身份：${task.id}\n${task.approvedAt == null ? '此记录没有批准时间。' : '批准时间：${task.approvedAt!.toLocal()}'}\n范围固定为 ${task.itemVersions.length} 条信息。整理已结束后不能继续读取或写入元数据。',
          style: prototypeText(context, 14, height: 1.85),
        ),
      ),
    );
  }

  Widget _deleteBody(ProposalEntry entry) {
    InformationItem? item;
    try {
      item = owner.previewDelete(entry.id);
    } on AccessFailure {
      return _conflict(entry, '删除提案的基础版本或目标字段已经变化。请检查当前信息，并让 Agent 重新提交。');
    }
    final proposal = owner.deleteProposals.firstWhere(
      (proposal) => proposal.id == entry.id,
    );
    final fields = item.fields.where(
      (field) => proposal.fieldId == null || field.id == proposal.fieldId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('待删除的信息', proposal.fieldId == null ? '1 条信息' : '选定字段'),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 21),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.paper,
                  border: Border.all(color: p.line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: PrototypeIcon(PrototypeIconGlyph.file, color: p.strong),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    t(item.name, 15, weight: FontWeight.w700),
                    const SizedBox(height: 7),
                    t(
                      '${directoryPath(owner, item.directoryId)} · ${fields.length} 个字段',
                      12,
                      color: p.muted,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: p.paper,
                  border: Border.all(color: p.line),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: t('版本 ${item.version}', 11, color: p.muted),
              ),
            ],
          ),
        ),
        for (final field in fields)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: BoxDecoration(
              color: p.rail,
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 150, child: t(field.name, 13)),
                const SizedBox(width: 20),
                Expanded(
                  child: InformationFieldContent(owner: owner, field: field),
                ),
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.only(top: 22),
          padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 16),
          decoration: BoxDecoration(
            color: p.rail,
            border: Border.all(color: p.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrototypeIcon(PrototypeIconGlyph.shield, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    t('移入回收站', 13, weight: FontWeight.w700, height: 21 / 13),
                    const SizedBox(height: 5),
                    t('确认后从信息库移除，可在回收站恢复。已提供给 Agent 的内容无法收回。', 13, height: 1.9),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  InformationEditorDraft _updateDraft(ProposalEntry entry) =>
      _updates.putIfAbsent(entry.id, () {
        final preview = owner.previewUpdate(entry.id);
        final input = preview.proposal.input;
        final fields = preview.before.fields
            .map((field) => EditableInformationField(original: field))
            .toList();
        for (final change in input.changes) {
          final index = fields.indexWhere(
            (field) => field.original?.id == change.fieldId,
          );
          switch (change.kind) {
            case FieldChangeKind.correct:
              fields[index].value = change.value!;
            case FieldChangeKind.remove:
              fields.removeAt(index);
            case FieldChangeKind.add:
              final field = change.field!;
              fields.add(
                EditableInformationField(
                  name: field.name,
                  description: field.description,
                  value: field.value,
                  kind: field.kind,
                ),
              );
            case FieldChangeKind.replace:
              final field = change.field!;
              fields[index] = EditableInformationField(
                original: fields[index].original,
                name: field.name,
                description: field.description,
                value: field.value,
                kind: field.kind,
                replaceIdentity: true,
              );
          }
        }
        return InformationEditorDraft(
          original: preview.before,
          name: input.name,
          description: input.description,
          fields: fields,
        );
      });
  UpdateReview _review(ProposalEntry entry) {
    final draft = _updateDraft(entry);
    return UpdateReview(
      UpdateInput(
        draft.original!.id,
        draft.original!.version,
        draft.changes,
        name: draft.name,
        description: draft.description,
      ),
      directoryId: draft.directoryId,
      tagIds: draft.tagIds,
      fieldDescriptions: draft.fieldDescriptions,
    );
  }

  Future<void> _editUpdate(ProposalEntry entry) async {
    _updateFocus.requestFocus();
    final source = _updateDraft(entry);
    final draft = InformationEditorDraft(
      original: source.original,
      name: source.name,
      description: source.description,
      directoryId: source.directoryId,
      tagIds: source.tagIds,
      fields: source.fields
          .map(
            (field) => EditableInformationField(
              original: field.original,
              name: field.name,
              description: field.description,
              value: field.value,
              kind: field.kind,
              replaceIdentity: field.replaceIdentity,
            ),
          )
          .toList(),
    )..directoryId = source.directoryId;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => InformationEditor(
        title: '调整修改内容',
        saveLabel: '保存提案调整',
        draft: draft,
        directories: owner.directories,
        tags: owner.tags,
        onSave: (edited) async {
          final current = owner.updateProposals
              .where((proposal) => proposal.id == entry.id)
              .firstOrNull;
          if (current?.state != UpdateProposalState.pending ||
              current!.version != entry.version) {
            throw const AccessFailure('information_conflict');
          }
          setState(() => _updates[entry.id] = edited);
        },
      ),
    );
    if (mounted) _updateFocus.requestFocus();
  }

  Widget _conflict(ProposalEntry entry, String reason) => Container(
    margin: const EdgeInsets.only(top: 22),
    padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 16),
    decoration: BoxDecoration(
      color: p.noticeWarningBackground,
      border: Border.all(color: p.noticeWarningBorder),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrototypeIcon(PrototypeIconGlyph.clock, color: p.noticeWarningInk),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              t(
                '信息已经发生变化',
                13,
                weight: FontWeight.w700,
                color: p.noticeWarningInk,
                height: 21 / 13,
              ),
              const SizedBox(height: 5),
              t(reason, 13, height: 1.9, color: p.noticeWarningInk),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _updateBody(ProposalEntry entry) {
    UpdatePreview? preview;
    try {
      preview = owner.previewUpdate(entry.id, review: _review(entry));
    } on AccessFailure {
      /* Render current identities, never a stale before snapshot. */
    }
    final proposal = owner.updateProposals.firstWhere(
      (proposal) => proposal.id == entry.id,
    );
    final current =
        preview?.before ??
        owner.information
            .where((item) => item.id == proposal.input.itemId)
            .firstOrNull;
    final draft = preview == null ? null : _updateDraft(entry);
    final rows = <(String, String, String)>[];
    if (draft != null) {
      for (final field in current!.fields) {
        final edited = draft.fields
            .where((candidate) => candidate.original?.id == field.id)
            .firstOrNull;
        if (edited == null) {
          rows.add((
            '${field.name} · 移除',
            informationFieldValueLabel(field),
            '移除字段',
          ));
        } else if (edited.replacesIdentity ||
            (field.kind != FieldKind.file && edited.value != field.value) ||
            edited.name != field.name ||
            edited.kind != field.kind) {
          rows.add((
            edited.replacesIdentity
                ? '${field.name} → ${edited.name} · 替换含义${field.kind == edited.kind ? '' : '（${_fieldKind(field.kind)} → ${_fieldKind(edited.kind)}）'}'
                : edited.name,
            informationFieldValueLabel(field),
            edited.kind == FieldKind.file ? '保留原文件与版本' : edited.value,
          ));
        }
        if (edited != null && edited.description != field.description) {
          rows.add((
            '${edited.name} · 公开说明',
            field.description,
            edited.description,
          ));
        }
      }
      for (final field in draft.fields.where(
        (field) => field.original == null,
      )) {
        rows.add(('${field.name} · 新增', '新增字段', field.value));
      }
      if (draft.name != current.name) {
        rows.add(('信息名称', current.name, draft.name));
      }
      if (draft.description != current.description) {
        rows.add(('公开说明', current.description, draft.description));
      }
      if (draft.directoryId != current.directoryId) {
        rows.add((
          '所在目录',
          directoryPath(owner, current.directoryId),
          directoryPath(owner, draft.directoryId),
        ));
      }
      final beforeTags = owner.tags
          .where((tag) => current.tagIds.contains(tag.id))
          .map((tag) => tag.name)
          .join('、');
      final afterTags = owner.tags
          .where((tag) => draft.tagIds.contains(tag.id))
          .map((tag) => tag.name)
          .join('、');
      if (beforeTags != afterTags) rows.add(('标签', beforeTags, afterTags));
    } else if (current != null) {
      for (final change in proposal.input.changes) {
        final field = current.fields
            .where((field) => field.id == change.fieldId)
            .firstOrNull;
        rows.add((
          field?.name ?? change.field?.name ?? '字段 ${change.fieldId}',
          field == null ? '当前字段已不存在' : informationFieldValueLabel(field),
          change.value ?? change.field?.value ?? '移除字段',
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (preview != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('edit-update'),
              focusNode: _updateFocus,
              style: prototypeButton(
                context,
                size: 12,
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 8,
                ),
                side: BorderSide(color: p.line),
              ),
              onPressed: _busy ? null : () => _editUpdate(entry),
              child: const Text('调整修改内容'),
            ),
          )
        else
          _conflict(
            entry,
            '提案基于版本 ${proposal.input.baseVersion}，${current == null ? '当前信息已不存在' : '当前是版本 ${current.version}'}。请让 Agent 基于最新内容重新提交，以免覆盖你的修改。',
          ),
        _heading(
          current?.name ?? '当前信息已不存在',
          '基于版本 ${proposal.input.baseVersion} · 当前版本 ${current?.version ?? '不存在'}',
        ),
        const SizedBox(height: 13),
        Row(
          children: [
            Expanded(
              child: t(
                directoryPath(owner, current?.directoryId),
                12,
                color: p.muted,
              ),
            ),
            t('未列出的字段保持原样', 12, color: p.muted),
          ],
        ),
        if (rows.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 20),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: p.line),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Column(
              children: [
                _diffLine('字段', '当前内容', '提案内容', heading: true),
                for (final row in rows) _diffLine(row.$1, row.$2, row.$3),
              ],
            ),
          ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: t('没有字段内容变化。确认仅应用上方元数据调整。', 13, color: p.muted),
          ),
        if (draft != null)
          for (final field in draft.fields.where(
            (field) =>
                field.kind == FieldKind.file &&
                field.original != null &&
                !field.replacesIdentity,
          ))
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  t('${field.name} · 保留原文件与版本', 13, weight: FontWeight.w600),
                  const SizedBox(height: 6),
                  InformationFieldContent(owner: owner, field: field.original!),
                ],
              ),
            ),
        if (draft != null &&
            draft.fields.any(
              (field) => field.original == null || field.replacesIdentity,
            ))
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: t(
              '新增或替换含义的字段会取得新身份，需要重新授权。旧字段的许可不会转移。',
              13,
              color: p.muted,
              height: 1.85,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Row(
            children: [
              PrototypeIcon(
                PrototypeIconGlyph.shield,
                size: 16,
                color: p.muted,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: t('确认修改不会扩大已有授权的字段范围。', 11, color: p.muted, height: 1.7),
              ),
            ],
          ),
        ),
        if (preview == null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: TextButton(
                style: prototypeButton(context, size: 13, foreground: p.strong),
                onPressed: () => _openResults(entry),
                child: const Text('查看当前信息，再让 Agent 基于最新版本重新提交 →'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _diffLine(
    String name,
    String before,
    String after, {
    bool heading = false,
  }) => Container(
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: p.line)),
      color: heading ? p.canvas : null,
    ),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 140,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
              child: t(
                name,
                heading ? 12 : 13,
                color: heading ? p.muted : null,
              ),
            ),
          ),
          for (final (index, value) in [before, after].indexed)
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 17,
                ),
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: p.line)),
                  color: heading
                      ? null
                      : index == 0
                      ? (p.isMono
                            ? const Color(0xfff5f5f6)
                            : const Color(0xfffaf5f3))
                      : p.rail,
                ),
                child: heading
                    ? t(value, 12, color: p.muted)
                    : _changedCode(value, index == 0 ? after : before),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _changedCode(String value, String other) {
    final actual = value.runes.toList(), compared = other.runes.toList();
    var prefix = 0, suffix = 0;
    while (prefix < actual.length &&
        prefix < compared.length &&
        actual[prefix] == compared[prefix]) {
      prefix++;
    }
    while (suffix < actual.length - prefix &&
        suffix < compared.length - prefix &&
        actual[actual.length - 1 - suffix] ==
            compared[compared.length - 1 - suffix]) {
      suffix++;
    }
    return SelectableText.rich(
      TextSpan(
        style: prototypeText(context, 13, family: 'Consolas', height: 1.6),
        children: [
          TextSpan(text: String.fromCharCodes(actual.take(prefix))),
          TextSpan(
            text: String.fromCharCodes(
              actual.skip(prefix).take(actual.length - prefix - suffix),
            ),
            style: TextStyle(
              backgroundColor: p.selected,
              color: p.strong,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: String.fromCharCodes(actual.skip(actual.length - suffix)),
          ),
        ],
      ),
    );
  }

  Widget _newItems(ProposalEntry entry) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('将要入库的内容', '整批确认 · 可逐条调整'),
      for (final (index, item) in _inputs(entry).indexed)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const PrototypeIcon(PrototypeIconGlyph.file),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        t(
                          item.name,
                          21,
                          family: 'SimSun',
                          weight: FontWeight.w500,
                        ),
                        for (final name in [
                          for (final tag in owner.tags.where(
                            (tag) => item.tagIds.contains(tag.id),
                          ))
                            tag.name,
                          ...item.suggestedTags,
                        ])
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: p.paper,
                              border: Border.all(color: p.line),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: t(name, 11, color: p.muted),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    key: ValueKey('edit-import-$index'),
                    focusNode: _importFocus.putIfAbsent(
                      '${entry.id}:$index',
                      FocusNode.new,
                    ),
                    onPressed: _busy ? null : () => _editImport(entry, index),
                    style: prototypeButton(
                      context,
                      size: 12,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 8,
                      ),
                      side: BorderSide(color: p.line),
                      background: p.paper,
                      foreground: p.ink,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const PrototypeIcon(PrototypeIconGlyph.edit, size: 15),
                        const SizedBox(width: 8),
                        const Text('调整'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  Expanded(
                    child: t(
                      item.directoryId == null &&
                              item.suggestedDirectory.isNotEmpty
                          ? item.suggestedDirectory
                          : item.directoryId != null &&
                                !owner.directories.any(
                                  (directory) =>
                                      directory.id == item.directoryId,
                                )
                          ? '不可用目录（${item.directoryId}）'
                          : directoryPath(owner, item.directoryId),
                      12,
                      color: p.muted,
                    ),
                  ),
                  t('${item.fields.length} 个字段', 12, color: p.muted),
                ],
              ),
              if (item.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: t(item.description, 13, color: p.muted, height: 1.85),
                ),
              const SizedBox(height: 10),
              for (final field in item.fields)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: p.rail,
                    border: Border(bottom: BorderSide(color: p.line)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            t(field.name, 13),
                            if (field.description.isNotEmpty)
                              t(
                                field.description,
                                12,
                                color: p.muted,
                                height: 1.8,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: SelectableText(
                          field.value,
                          style: prototypeText(
                            context,
                            13,
                            family: field.kind == FieldKind.textNote
                                ? null
                                : 'Consolas',
                            height: 1.6,
                          ),
                          // Keep the CSS code line box when CJK uses fallback.
                          strutStyle: StrutStyle(
                            fontFamily: field.kind == FieldKind.textNote
                                ? 'ProductSans'
                                : 'Consolas',
                            fontFamilyFallback: const [
                              'ProductSans',
                              'AppSans',
                              'Songti SC',
                            ],
                            fontSize: 13,
                            height: 1.6,
                            forceStrutHeight: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
    ],
  );
  Widget _receipt(ProposalEntry entry) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        t('处理回执', 16, weight: FontWeight.w700),
        t('${entry.stateLabel} · ${entry.id}', 14),
        t('回执保留处理事实，不重新显示提案中的字段内容。', 14),
        if (entry.kind == ProposalKind.addition)
          for (final name
              in owner.importProposals
                  .firstWhere((proposal) => proposal.id == entry.id)
                  .itemNames)
            Padding(padding: const EdgeInsets.only(top: 8), child: t(name, 14)),
        const SizedBox(height: 16),
        TextButton(
          style: prototypeSecondary(context),
          onPressed: () => _openResults(entry),
          child: const Text('按信息身份查看当前内容 →'),
        ),
      ],
    ),
  );
  Future<void> _openResults(ProposalEntry entry) => showDialog<void>(
    context: context,
    barrierColor: const Color(0x4f241b27),
    builder: (_) => _CurrentResults(
      owner: owner,
      ids: entry.itemIds,
      onOpenInformation: widget.onOpenInformation,
    ),
  );
  Widget _actions(ProposalEntry entry) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
    decoration: BoxDecoration(
      color: p.rail,
      border: Border(top: BorderSide(color: p.line)),
    ),
    child: Row(
      children: [
        Expanded(
          child: t(
            entry.kind == ProposalKind.organization
                ? ''
                : entry.pending
                ? (entry.status == ProposalStatus.conflicted
                      ? '存在版本冲突，暂时无法采用这次修改。'
                      : '确认前不会改变信息库；调整只作用于当前提案。')
                : '此提案已处理，可继续核对其他待确认内容。',
            12,
            color: p.muted,
            height: 1.8,
          ),
        ),
        const SizedBox(width: 16),
        if (entry.pending) ...[
          TextButton(
            focusNode: _rejectFocus,
            style: prototypeButton(context, size: 12, foreground: p.strong),
            onPressed: _busy ? null : () => _decide(entry, false),
            child: const Text('拒绝提案'),
          ),
          const SizedBox(width: 16),
          Opacity(
            opacity: _busy || entry.status == ProposalStatus.conflicted
                ? .45
                : 1,
            child: TextButton(
              key: const ValueKey('proposal-action-confirm'),
              focusNode: _confirmFocus,
              style: prototypePrimary(context).copyWith(
                foregroundColor: WidgetStatePropertyAll(p.paper),
                backgroundColor: WidgetStatePropertyAll(p.accent),
                minimumSize: const WidgetStatePropertyAll(Size(165, 0)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                ),
              ),
              onPressed: _busy || entry.status == ProposalStatus.conflicted
                  ? null
                  : () => _decide(entry, true),
              child: SizedBox(
                height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.kind == ProposalKind.addition
                          ? '确认全部入库'
                          : entry.kind == ProposalKind.deletion
                          ? '确认移入回收站'
                          : '确认这些修改',
                    ),
                    const SizedBox(width: 16),
                    const Text('→'),
                  ],
                ),
              ),
            ),
          ),
        ] else
          TextButton(
            style: prototypeSecondary(context),
            onPressed: () => widget.onGoToLibrary != null
                ? widget.onGoToLibrary!()
                : _openResults(entry),
            child: SizedBox(
              height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
              child: const Text('前往信息库'),
            ),
          ),
      ],
    ),
  );
  String _time(DateTime value) =>
      '${value.toLocal().hour.toString().padLeft(2, '0')}:${value.toLocal().minute.toString().padLeft(2, '0')}';
}

class _CurrentResults extends StatefulWidget {
  const _CurrentResults({
    required this.owner,
    required this.ids,
    this.onOpenInformation,
  });
  final OwnerAccess owner;
  final List<String> ids;
  final ValueChanged<String>? onOpenInformation;
  @override
  State<_CurrentResults> createState() => _CurrentResultsState();
}

class _CurrentResultsState extends State<_CurrentResults> {
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

  Widget _paragraph(String value) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: prototypeCh(context, 14, 48)),
      child: Text(value, style: prototypeText(context, 14, height: 1.85)),
    ),
  );

  @override
  Widget build(BuildContext context) => PrototypeDialog(
    flow: true,
    title: '当前信息',
    onClose: () => Navigator.pop(context),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.owner.serviceAvailable)
          _paragraph('信息库暂不可用，请恢复服务后重试。')
        else ...[
          for (final id in widget.ids)
            Builder(
              builder: (context) {
                final item = widget.owner.information
                    .where((item) => item.id == id)
                    .firstOrNull;
                if (item == null) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: _paragraph('当前信息已不存在（$id）\n可到回收站检查。'),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item.name,
                        style: prototypeText(
                          context,
                          18,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _paragraph(item.description),
                      for (final field in item.fields)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                field.name,
                                style: prototypeText(
                                  context,
                                  13,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 7),
                              InformationFieldContent(
                                owner: widget.owner,
                                field: field,
                              ),
                            ],
                          ),
                        ),
                      if (widget.onOpenInformation != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            style: prototypeSecondary(context),
                            onPressed: () {
                              if (!widget.owner.serviceAvailable ||
                                  !widget.owner.information.any(
                                    (current) => current.id == id,
                                  )) {
                                setState(() {});
                                return;
                              }
                              Navigator.pop(context);
                              widget.onOpenInformation!(id);
                            },
                            child: const Text('在信息库打开 →'),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          if (widget.ids.isEmpty) _paragraph('此回执没有已入库的信息身份。'),
        ],
      ],
    ),
  );
}
