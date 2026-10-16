import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'organization_tasks.dart';
import 'ui.dart';
import 'inbox_queue.dart';
import 'package:flutter/services.dart';

class SearchInboxIntent extends Intent {
  const SearchInboxIntent();
}

class Approvals extends StatefulWidget {
  const Approvals({
    super.key,
    required this.service,
    required this.port,
    this.focusRequestId,
    this.focusRevision = 0,
  });
  final InformationService service;
  final int port;
  final String? focusRequestId;
  final int focusRevision;
  @override
  State<Approvals> createState() => ApprovalsState();
}

class ApprovalsState extends State<Approvals> {
  void focusSearch() => _searchFocus.requestFocus();
  Timer? _refresh;
  final _scopeScrolls = <String, ScrollController>{};
  ScrollController get _scopeScroll =>
      _scopeScrolls.putIfAbsent(_focused ?? 'none', () => ScrollController());
  final _queueScrolls = <String, ScrollController>{};
  final _documentScrolls = <String, ScrollController>{};
  final _errors = <String, String>{};
  String? get _actionError => _errors[_focused];
  set _actionError(String? value) {
    if (_focused == null) return;
    if (value == null) {
      _errors.remove(_focused);
    } else {
      _errors[_focused!] = value;
    }
  }

  final _busy = <String>{};
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  InboxFilter _filter = InboxFilter.all;
  int _offset = 0;
  final _pageFocus = <String, String>{};
  String? _notificationFocus;
  bool _missingNotification = false;
  InboxPage? _lastPage;
  String get _pageKey => '${_filter.name}/${_search.text}/$_offset';
  @override
  void didUpdateWidget(covariant Approvals oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusRevision != oldWidget.focusRevision) {
      _notificationFocus = widget.focusRequestId;
      _filter = InboxFilter.all;
      _search.clear();
    }
  }

  String? _focused;
  final _selection = <String, Set<FieldRef>>{};
  final _organizationSelection = <String, Set<String>>{};
  final _grantMinutes = <String, int>{};
  final _expandedScope = <String>{};
  @override
  void initState() {
    super.initState();
    _notificationFocus = widget.focusRequestId;
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    for (final controller in [
      ..._queueScrolls.values,
      ..._documentScrolls.values,
      ..._scopeScrolls.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _manage(VoidCallback action) async {
    final id = _focused;
    if (id == null || !_busy.add(id)) return;
    setState(() => _errors.remove(id));
    try {
      if (!widget.service.owner.serviceAvailable) {
        throw const AccessFailure('service_unavailable');
      }
      action();
      await widget.service.owner.history();
    } catch (error) {
      if (mounted) {
        setState(
          () => _errors[id] = switch (error) {
            AccessFailure(status: 'invalid_scope') =>
              '所选字段已不可用，或超过200个。请重新检查最终选择。',
            AccessFailure(status: 'invalid_duration') => '授权有效期须为1至10080分钟。',
            AccessFailure(status: 'audit_unavailable') =>
              '决定已记录，但记录保存异常，信息读取暂停。请到授权历史重试保存记录。',
            AccessFailure(status: 'service_unavailable') =>
              '本机服务暂不可用，选择已保留。请恢复服务后重试。',
            _ => '请求状态或资料已变化。选择已保留，请重新检查后重试。',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  bool _retryingAudit = false;
  Future<void> _retryAudit() async {
    if (_retryingAudit) return;
    setState(() => _retryingAudit = true);
    try {
      await widget.service.owner.retryAuditStorage();
      if (mounted) setState(_errors.clear);
    } catch (_) {
      if (mounted) setState(() => _actionError = '记录仍未保存，请检查存储后重试。已有决定保持不变。');
    } finally {
      if (mounted) setState(() => _retryingAudit = false);
    }
  }

  Future<void> _settings() => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => DesktopDialog(
        title: const Text('请求设置'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('待审批有效期'),
              const SizedBox(height: 12),
              DesktopSelect<int>(
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
    final owner = widget.service.owner;
    final offline = !owner.serviceAvailable;
    final page = offline
        ? (_lastPage ??
              InboxPage([], total: 0, pendingCount: 0, offset: 0, limit: 20))
        : owner.queryInbox(
            search: _search.text,
            filter: _filter,
            offset: _offset,
            focusRequestId: _notificationFocus ?? _focused,
          );
    if (!offline) _lastPage = page;
    _offset = page.offset;
    if (_notificationFocus != null) {
      _focused = _notificationFocus;
      _missingNotification = !page.entries.any(
        (entry) => entry.id == _notificationFocus,
      );
      _notificationFocus = null;
    }
    if (!page.entries.any((r) => r.id == _focused)) {
      final remembered = _pageFocus[_pageKey];
      _focused = page.entries.any((r) => r.id == remembered)
          ? remembered
          : page.entries.firstOrNull?.id;
    }
    final current = _missingNotification
        ? null
        : page.entries.where((r) => r.id == _focused).firstOrNull;
    if (_focused != null) _pageFocus[_pageKey] = _focused!;
    final colors = UiPalette.of(context);
    final queue = InboxQueue(
      page: page,
      focused: _focused,
      searchController: _search,
      searchFocus: _searchFocus,
      filter: _filter,
      onSearch: (_) => setState(() {
        _missingNotification = false;
        _offset = 0;
        _focused = null;
      }),
      onFilter: (filter) => setState(() {
        _missingNotification = false;
        _filter = filter;
        _offset = 0;
        _focused = null;
      }),
      onPage: (offset) => setState(() {
        _offset = offset;
        _focused = _pageFocus[_pageKey];
      }),
      onSelected: (id) => setState(() {
        _missingNotification = false;
        _focused = id;
        _pageFocus[_pageKey] = id;
      }),
      stateLabel: _entryState,
      scrollController: _queueScrolls.putIfAbsent(
        _pageKey,
        () => ScrollController(),
      ),
    );
    final largeType = MediaQuery.textScalerOf(context).scale(14) > 20;
    final detail = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!largeType)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '访问审批  ›  请求详情',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _settings,
                  icon: const Icon(Icons.tune, size: 17),
                  label: const Text('请求设置'),
                ),
              ],
            ),
          ),
        if (offline)
          const QuietNotice('本机服务暂不可用。当前选择已保留，请恢复服务；资料库不会被覆盖。', warning: true),
        if (_missingNotification)
          const QuietNotice('这条通知对应的请求已不可用。请从收件箱选择当前请求。'),
        if (owner.auditStorageUnavailable)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              const Text('记录保存异常，信息读取已暂停。'),
              OutlinedButton(
                onPressed: _retryingAudit ? null : _retryAudit,
                child: Text(_retryingAudit ? '正在保存…' : '重试保存记录'),
              ),
            ],
          ),
        Expanded(
          child: current == null
              ? const EmptyWorkspace(
                  icon: Icons.inbox_outlined,
                  title: '没有找到请求',
                  description: 'Agent 提交申请后，这里会列出用途和所需信息。可调整或清除筛选。',
                )
              : Material(
                  color: colors.paper,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: colors.line),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: current.organization != null
                        ? OrganizationApprovalPanel(
                            key: ValueKey(current.id),
                            owner: owner,
                            task: current.organization!,
                            selected: _organizationSelection.putIfAbsent(
                              current.id,
                              () => current.organization!.itemVersions.keys
                                  .toSet(),
                            ),
                            onChanged: () => setState(() {}),
                          )
                        : _requestView(current.access!),
                  ),
                ),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.slash): () =>
            _searchFocus.requestFocus(),
      },
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: LayoutBuilder(
          builder: (context, bounds) {
            final compact =
                bounds.maxWidth < 760 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            if (compact) {
              return Column(
                children: [
                  _compactControls(page, current, bounds.maxWidth),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                      child: detail,
                    ),
                  ),
                ],
              );
            }
            return Row(
              children: [
                SizedBox(
                  width: bounds.maxWidth < 1100 ? 250 : 300,
                  child: queue,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(26, 20, 26, 18),
                    child: detail,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _compactControls(InboxPage page, InboxEntry? current, double width) {
    final search = DesktopTextField(
      key: const ValueKey('inbox-search'),
      maxLength: 2000,
      controller: _search,
      focusNode: _searchFocus,
      decoration: const InputDecoration(
        hintText: '搜索请求',
        prefixIcon: Icon(Icons.search),
      ),
      onChanged: (_) => setState(() {
        _offset = 0;
        _focused = null;
        _missingNotification = false;
      }),
    );
    final picker = DesktopSelect<String>(
      key: const ValueKey('request-picker'),
      value: current?.id,
      isExpanded: true,
      items: [
        for (final entry in page.entries)
          DropdownMenuItem(
            value: entry.id,
            child: Text(
              '${entry.chatLabel} · ${_entryState(entry)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (id) => setState(() {
        _focused = id;
        _missingNotification = false;
      }),
    );
    final filter = SizedBox(
      width: 150,
      child: DesktopSelect<InboxFilter>(
        key: const ValueKey('inbox-status-picker'),
        value: _filter,
        isExpanded: true,
        items: [
          for (final value in InboxFilter.values)
            DropdownMenuItem(
              value: value,
              child: Text(switch (value) {
                InboxFilter.all => '全部',
                InboxFilter.pending => '待处理',
                InboxFilter.handled => '已处理',
              }),
            ),
        ],
        onChanged: (value) {
          if (value != null) {
            setState(() {
              _filter = value;
              _offset = 0;
              _focused = null;
              _missingNotification = false;
            });
          }
        },
      ),
    );
    final paging = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上一页请求',
          onPressed: _offset == 0
              ? null
              : () => setState(() {
                  _offset -= 20;
                  _focused = null;
                  _missingNotification = false;
                }),
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: '下一页请求',
          onPressed: _offset + 20 >= page.total
              ? null
              : () => setState(() {
                  _offset += 20;
                  _focused = null;
                  _missingNotification = false;
                }),
          icon: const Icon(Icons.chevron_right),
        ),
        IconButton(
          tooltip: '请求设置',
          onPressed: _settings,
          icon: const Icon(Icons.tune),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: width >= 1100
          ? Row(
              children: [
                SizedBox(width: 300, child: search),
                const SizedBox(width: 12),
                Expanded(child: picker),
                const SizedBox(width: 12),
                filter,
                paging,
              ],
            )
          : Column(
              children: [
                Row(
                  children: [
                    Expanded(child: search),
                    paging,
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: picker),
                    const SizedBox(width: 12),
                    filter,
                  ],
                ),
              ],
            ),
    );
  }

  String _entryState(InboxEntry entry) => entry.access != null
      ? _state(entry.access!.state)
      : organizationStateLabel(entry.organizationState!);

  Widget _requestView(OwnerRequestSnapshot request) {
    final selected = _selection.putIfAbsent(
      request.id,
      () => request.fields.toSet(),
    );
    final available = widget.service.owner.information
        .expand((item) => item.fields.map((f) => FieldRef(item.id, f.id)))
        .toSet();
    return LayoutBuilder(
      builder: (context, size) {
        final wide =
            size.maxWidth >= 780 &&
            MediaQuery.textScalerOf(context).scale(14) <= 20;
        final document = _requestDocument(request, selected, available);
        final decision = _decision(request, selected, compact: !wide);
        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: document),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 270,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: size.maxHeight),
                        child: decision,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  Expanded(child: document),
                  if (request.state == AccessRequestState.pending)
                    decision
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: size.maxHeight * .55,
                      ),
                      child: decision,
                    ),
                ],
              );
      },
    );
  }

  Widget _requestDocument(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected,
    Set<FieldRef> available,
  ) {
    final pending = request.state == AccessRequestState.pending;
    final expanded = _expandedScope.contains(request.id);
    final extras = {
      ...available,
      ...selected,
    }.where((f) => !request.fields.contains(f)).toList();
    final groups = <String, List<FieldRef>>{};
    for (final field in request.fields) {
      groups.putIfAbsent(field.itemId, () => []).add(field);
    }
    final largeType = MediaQuery.textScalerOf(context).scale(14) > 20;
    final scroll = _documentScrolls.putIfAbsent(
      request.id,
      () => ScrollController(),
    );
    return Scrollbar(
      controller: scroll,
      thumbVisibility: true,
      child: ListView(
        controller: scroll,
        key: PageStorageKey('detail-${request.id}'),
        padding: const EdgeInsets.fromLTRB(4, 14, 10, 20),
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusLabel(
                _state(request.state),
                active: request.state == AccessRequestState.approved,
                attention: pending,
              ),
              if (pending)
                Text(
                  '待审批剩余：${request.remainingSeconds ~/ 60} 分 ${request.remainingSeconds % 60} 秒',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          if (!largeType) ...[
            const SizedBox(height: 10),
            Text(
              '聊天：${request.chatLabel}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
          ],
          Text(request.purpose, style: Theme.of(context).textTheme.bodyLarge),
          SizedBox(height: largeType ? 4 : 8),
          Text(
            '聊天名称与用途由 agent 自述，仅供判断。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: largeType ? 6 : 18),
          SectionHeading('Agent 申请范围', detail: '${request.fields.length} 个字段'),
          for (final group in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(
                widget.service.owner.information
                        .where((item) => item.id == group.key)
                        .firstOrNull
                        ?.name ??
                    '原信息已不可用',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final field in group.value)
              pending
                  ? _scopeField(field, selected, available)
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        widget.service.owner.information
                                .where((i) => i.id == field.itemId)
                                .firstOrNull
                                ?.fields
                                .where((f) => f.id == field.fieldId)
                                .firstOrNull
                                ?.name ??
                            field.fieldId,
                      ),
                    ),
            const SizedBox(height: 14),
          ],
          if (pending) ...[
            if (!expanded && extras.any(selected.contains)) ...[
              const SectionHeading('补选的字段'),
              for (final field in extras.where(selected.contains))
                _scopeField(field, selected, available),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  expanded
                      ? _expandedScope.remove(request.id)
                      : _expandedScope.add(request.id);
                }),
                icon: Icon(expanded ? Icons.expand_less : Icons.add, size: 17),
                label: Text(expanded ? '收起补选范围' : '补选或改选字段'),
              ),
            ),
            if (expanded) ...[
              const SizedBox(height: 12),
              for (final directory in widget.service.owner.directories)
                _directorySelection(request.id, directory, selected),
              for (final field in extras)
                _scopeField(field, selected, available),
            ],
          ],
          if (MediaQuery.sizeOf(context).width < 1100 ||
              MediaQuery.textScalerOf(context).scale(14) > 20)
            const QuietNotice('仅提供选中字段；新增内容需另行申请。撤销无法收回已提供的内容。'),
        ],
      ),
    );
  }

  Widget _decision(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected, {
    required bool compact,
  }) {
    final pending = request.state == AccessRequestState.pending;
    final busy =
        _busy.contains(request.id) || !widget.service.owner.serviceAvailable;
    final minutes = _grantMinutes[request.id] ?? 480;
    final valid = minutes >= 1 && minutes <= 10080;
    final scopeChange =
        '原申请 ${request.fields.length} · 未选 ${request.fields.where((field) => !selected.contains(field)).length} · 补选 ${selected.where((field) => !request.fields.contains(field)).length}';
    final lifetime = SizedBox(
      width: compact ? 176 : double.infinity,
      child: DesktopTextFormField(
        key: ValueKey('grant-lifetime-${request.id}'),
        initialValue: '$minutes',
        enabled: !busy,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: compact ? null : '有效期（分钟）',
          suffixText: compact ? '分钟' : null,
          helperText: !compact && valid
              ? '${_durationLabel(minutes)} · 读取不续期'
              : null,
          errorText: valid ? null : '请输入 1 至 10080 的整数',
        ),
        onChanged: (v) => setState(() {
          _grantMinutes[request.id] = int.tryParse(v) ?? 0;
          _actionError = null;
        }),
      ),
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton(
          onPressed: busy
              ? null
              : () => _manage(() => widget.service.owner.deny(request.id)),
          child: const Text('拒绝申请'),
        ),
        FilledButton.icon(
          key: const ValueKey('approve-selection'),
          onPressed: busy || selected.isEmpty || !valid
              ? null
              : () => _manage(
                  () => widget.service.owner.approve(
                    request.id,
                    selected.toList(),
                    lifetime: Duration(minutes: minutes),
                  ),
                ),
          icon: Icon(Icons.check, size: 17),
          label: Text(_busy.contains(request.id) ? '正在保存…' : '批准所选字段'),
        ),
      ],
    );
    final policy = Text(
      '仅提供选中字段；新增内容需另行申请。撤销无法收回已提供的内容。',
      style: Theme.of(context).textTheme.bodySmall,
    );
    if (!pending) {
      final scope = request.approvedFields == null
          ? const SizedBox()
          : request.approvedFields!.length == 1
          ? Text('已批准字段：${request.approvedFields!.map(_fieldLabel).join('、')}')
          : _scopeGroups(request.approvedFields!);
      final body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeading('本次申请已处理'),
          if (_busy.contains(request.id))
            const QuietNotice('决定正在保存，信息读取等待记录写入。'),
          if (request.sessionEnded) const QuietNotice('聊天已结束。恢复聊天需要重新连接并申请授权。'),
          if (request.approvedFields != null) ...[
            if (compact)
              scope
            else
              Flexible(
                fit: FlexFit.loose,
                child: Scrollbar(
                  controller: _scopeScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scopeScroll,
                    child: scope,
                  ),
                ),
              ),
            const SizedBox(height: 18),
            Text(
              '到期时间：${uiTime(request.grantExpiresAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (request.state == AccessRequestState.approved)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => _manage(
                          () => widget.service.owner.revoke(request.id),
                        ),
                  child: const Text('撤销授权'),
                ),
              ),
            ),
          if (_actionError != null) QuietNotice(_actionError!, warning: true),
        ],
      );
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: UiPalette.of(context).rail,
          borderRadius: BorderRadius.circular(6),
        ),
        child: compact ? SingleChildScrollView(child: body) : body,
      );
    }
    return Container(
      key: ValueKey('decision-${request.id}'),
      padding: EdgeInsets.all(compact ? 14 : 22),
      decoration: BoxDecoration(
        color: UiPalette.of(context).rail,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: UiPalette.of(context).line),
      ),
      child: compact
          ? LayoutBuilder(
              builder: (context, bounds) {
                final summary = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => DesktopDialog(
                          title: Text('本次授权范围 · ${selected.length} 个字段'),
                          content: SizedBox(
                            width: 600,
                            height: 420,
                            child: SingleChildScrollView(
                              child: _scopeGroups(selected),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('返回审批'),
                            ),
                          ],
                        ),
                      ),
                      child: Text('最终选择 ${selected.length} 个字段'),
                    ),
                    Text(
                      scopeChange,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      valid
                          ? '有效期 ${_durationLabel(minutes)} · 读取不续期'
                          : '有效期有误',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
                final controls = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(label: '授权有效期（分钟）', child: lifetime),
                    const SizedBox(width: 16),
                    actions,
                  ],
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (bounds.maxWidth >= 650)
                      Row(
                        children: [
                          Expanded(child: summary),
                          const SizedBox(width: 12),
                          controls,
                        ],
                      )
                    else ...[
                      summary,
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [lifetime, actions],
                      ),
                    ],
                    if (_actionError != null)
                      QuietNotice(_actionError!, warning: true),
                  ],
                );
              },
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeading('本次授权'),
                Text(
                  request.chatLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Flexible(
                  fit: FlexFit.loose,
                  child: Scrollbar(
                    controller: _scopeScroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scopeScroll,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '最终选择 ${selected.length} 个字段',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            scopeChange,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          if (selected.isEmpty)
                            const Text('尚未选择字段')
                          else
                            _scopeGroups(selected),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                lifetime,
                const SizedBox(height: 8),
                actions,
                if (_actionError != null)
                  QuietNotice(_actionError!, warning: true),
                const SizedBox(height: 18),
                policy,
              ],
            ),
    );
  }

  Widget _scopeGroups(Iterable<FieldRef> refs) {
    final groups = <String, List<FieldRef>>{};
    for (final ref in refs) {
      groups.putIfAbsent(ref.itemId, () => []).add(ref);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              widget.service.owner.information
                      .where((i) => i.id == group.key)
                      .firstOrNull
                      ?.name ??
                  group.key,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final ref in group.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Text(
                '· ${widget.service.owner.information.where((i) => i.id == ref.itemId).firstOrNull?.fields.where((f) => f.id == ref.fieldId).firstOrNull?.name ?? ref.fieldId}',
              ),
            ),
        ],
      ],
    );
  }

  Widget _scopeField(
    FieldRef ref,
    Set<FieldRef> selected,
    Set<FieldRef> available,
  ) {
    final item = widget.service.owner.information
        .where((i) => i.id == ref.itemId)
        .firstOrNull;
    final field = item?.fields.where((f) => f.id == ref.fieldId).firstOrNull;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
        ),
        child: CheckboxListTile(
          key: ValueKey('field-${ref.fieldId}'),
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 2,
            vertical: 0,
          ),
          title: Text(field?.name ?? _fieldLabel(ref)),
          subtitle: !available.contains(ref)
              ? Text(
                  '字段已不可用，请取消选择或改选其他字段',
                  style: TextStyle(color: UiPalette.of(context).danger),
                )
              : field == null
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (field.description.isNotEmpty) Text(field.description),
                    Text(
                      field.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontFamilyFallback: ['AppSans'],
                        fontSize: 13,
                      ),
                    ),
                    if (field.value.length > 200 || field.value.contains('\n'))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => DesktopDialog(
                              title: const Text('查看完整字段值'),
                              content: SizedBox(
                                width: 680,
                                height: 420,
                                child: SingleChildScrollView(
                                  child: SelectableText(field.value),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('返回审批'),
                                ),
                              ],
                            ),
                          ),
                          child: const Text('查看完整值'),
                        ),
                      ),
                  ],
                ),
          value: selected.contains(ref),
          onChanged:
              _busy.contains(_focused) || !widget.service.owner.serviceAvailable
              ? null
              : (v) => setState(() {
                  v == true ? selected.add(ref) : selected.remove(ref);
                  _actionError = null;
                }),
        ),
      ),
    );
  }

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
      onChanged:
          _busy.contains(_focused) ||
              !widget.service.owner.serviceAvailable ||
              fields.isEmpty
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
