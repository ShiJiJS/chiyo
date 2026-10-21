import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'organization_tasks.dart';
import 'credential_use_approval.dart';
import 'ui.dart';
import 'inbox_queue.dart';
import 'prototype_ui.dart';
import 'prototype_dialog.dart';
import 'information_file_summary.dart';
import 'package:flutter/services.dart';

class SearchInboxIntent extends Intent {
  const SearchInboxIntent();
}

/// A printable slash belongs to the focused editor, including modal dialogs.
class SearchInboxActivator extends SingleActivator {
  const SearchInboxActivator() : super(LogicalKeyboardKey.slash);

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final focused = FocusManager.instance.primaryFocus?.context;
    final editing =
        focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null;
    return !editing && super.accepts(event, state);
  }
}

class Approvals extends StatefulWidget {
  const Approvals({
    super.key,
    required this.service,
    required this.port,
    this.focusRequestId,
    this.focusRevision = 0,
    this.onOpenSettings,
  });
  final InformationService service;
  final int port;
  final String? focusRequestId;
  final int focusRevision;
  final VoidCallback? onOpenSettings;
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
  final _loadedFiles = <String, Set<InformationAttachmentRef>>{};
  InformationField? _currentField(FieldRef ref) => widget
      .service
      .owner
      .information
      .where((item) => item.id == ref.itemId)
      .firstOrNull
      ?.fields
      .where((field) => field.id == ref.fieldId)
      .firstOrNull;
  Map<FieldRef, int> _reviewedVersions(Iterable<FieldRef> refs) => {
    for (final ref in refs)
      if (_currentField(ref) case final field?) ref: field.version,
  };
  bool _filesReady(Iterable<FieldRef> refs) => refs.every((ref) {
    final field = _currentField(ref);
    return field?.kind != FieldKind.file ||
        (_loadedFiles[_focused]?.contains(field!.attachment) ?? false);
  });
  String _scopeName(FieldRef ref) {
    final field = _currentField(ref);
    return field == null
        ? _fieldLabel(ref)
        : '${field.name}${field.kind == FieldKind.file ? '（文件 · 领取原文件）' : ''}';
  }

  RecordedField? _recordedField(FieldRef ref) => _lastPage?.entries
      .where((entry) => entry.id == _focused)
      .firstOrNull
      ?.access
      ?.recordedFields
      .where(
        (field) => field.itemId == ref.itemId && field.fieldId == ref.fieldId,
      )
      .firstOrNull;

  String _itemLabel(String id) =>
      widget.service.owner.information
          .where((item) => item.id == id)
          .firstOrNull
          ?.name ??
      _lastPage?.entries
          .where((entry) => entry.id == _focused)
          .firstOrNull
          ?.access
          ?.recordedFields
          .where((field) => field.itemId == id)
          .firstOrNull
          ?.itemName ??
      '信息名称未记录';

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
  final _organizationMinutes = <String, int>{};
  final _credentialDrafts = <String, CredentialUseApprovalDraft>{};
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
            AccessFailure(status: 'scope_changed') =>
              '字段或文件版本已变化。选择已保留，请重新核对后再批准。',
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

  Future<void> _settings() async {
    if (widget.onOpenSettings != null) {
      widget.onOpenSettings!();
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (context) => StatefulBuilder(
        builder: (context, update) => PrototypeDialog(
          title: '请求设置',
          onClose: () => Navigator.pop(context),
          body: SizedBox(
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
              style: prototypeSecondary(context),
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.service.owner;
    final offline = !owner.serviceAvailable;
    final page = offline
        ? (_lastPage ??
              InboxPage([], total: 0, pendingCount: 0, offset: 0, limit: 8))
        : owner.queryInbox(
            search: _search.text,
            filter: _filter,
            offset: _offset,
            limit: 8,
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
        if (!largeType) ...[
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Text(
                  '访问审批',
                  style: prototypeText(context, 12, color: colors.muted),
                ),
                const SizedBox(width: 10),
                const PrototypeIcon(PrototypeIconGlyph.chev, size: 13),
                const SizedBox(width: 10),
                Text(
                  '请求详情',
                  style: prototypeText(context, 12, weight: FontWeight.w500),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _settings,
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    background: colors.paper,
                    side: BorderSide(color: colors.line),
                    radius: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const PrototypeIcon(PrototypeIconGlyph.tune, size: 15),
                      const SizedBox(width: 8),
                      const Text('请求设置'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (offline)
          const QuietNotice(
            '本机服务暂不可用。当前选择已保留，请恢复服务；信息库不会被覆盖。',
            warning: true,
            panel: true,
          ),
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
              : Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: colors.paper,
                    border: Border.all(color: colors.line),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0632202d),
                        offset: Offset(0, 3),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: current.credentialUse != null
                        ? CredentialUseApprovalPanel(
                            key: ValueKey(current.id),
                            owner: owner,
                            request: current.credentialUse!,
                            draft: _credentialDrafts.putIfAbsent(
                              current.id,
                              () => CredentialUseApprovalDraft(
                                current.credentialUse!.fields,
                              ),
                            ),
                            onChanged: () => setState(() {}),
                          )
                        : current.organization != null
                        ? OrganizationApprovalPanel(
                            key: ValueKey(current.id),
                            owner: owner,
                            task: current.organization!,
                            remainingSeconds:
                                current.organizationRemainingSeconds,
                            minutes: _organizationMinutes[current.id] ?? 30,
                            onMinutesChanged: (value) => setState(
                              () => _organizationMinutes[current.id] = value,
                            ),
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
        if (!largeType)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              children: [
                Text(
                  '每次提供信息，都由你决定范围。',
                  style: prototypeText(context, 11, color: colors.muted),
                ),
                const Spacer(),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.muted,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '信息保存在本机',
                  style: prototypeText(context, 11, color: colors.muted),
                ),
              ],
            ),
          ),
      ],
    );
    return CallbackShortcuts(
      bindings: {
        const SearchInboxActivator(): () => _searchFocus.requestFocus(),
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
                SizedBox(width: 310, child: queue),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 23, 28, 14),
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
                  _offset -= 8;
                  _focused = null;
                  _missingNotification = false;
                }),
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: '下一页请求',
          onPressed: _offset + 8 >= page.total
              ? null
              : () => setState(() {
                  _offset += 8;
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
      : entry.credentialUse != null
      ? credentialUseStateLabel(entry.credentialUseState!)
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
                  SizedBox(width: 244, child: decision),
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
    final c = UiPalette.of(context);
    final pending = request.state == AccessRequestState.pending;
    final pendingInk = c.statusAttention;
    final extras = {
      ...available,
      ...selected,
    }.where((f) => !request.fields.contains(f)).toList();
    final groups = <String, List<FieldRef>>{};
    for (final field in [
      ...request.fields,
      ...extras.where(selected.contains),
    ]) {
      groups.putIfAbsent(field.itemId, () => []).add(field);
    }
    final largeType = MediaQuery.textScalerOf(context).scale(14) > 20;
    final scroll = _documentScrolls.putIfAbsent(
      request.id,
      () => ScrollController(),
    );
    return Scrollbar(
      controller: scroll,
      thumbVisibility:
          groups.values.fold<int>(0, (n, f) => n + f.length) > 4 || largeType,
      child: ListView(
        primary: false,
        controller: scroll,
        key: PageStorageKey('detail-${request.id}'),
        padding: EdgeInsets.fromLTRB(30, largeType ? 10 : 24, 30, 24),
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: pending ? pendingInk : c.muted,
                    width: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                _state(request.state),
                style: prototypeText(
                  context,
                  12,
                  color: pending ? pendingInk : c.muted,
                ),
              ),
              const SizedBox(width: 12),
              Text('读取信息', style: prototypeText(context, 12, color: c.muted)),
              if (pending && !largeType) ...[
                const Spacer(),
                const PrototypeIcon(PrototypeIconGlyph.clock, size: 16),
                const SizedBox(width: 7),
                Text(
                  '还剩 ${(request.remainingSeconds / 60).ceil()} 分钟',
                  style: prototypeText(context, 12, color: c.muted),
                ),
              ],
            ],
          ),
          if (!largeType) ...[
            const SizedBox(height: 12),
            Text(
              request.chatLabel,
              style: prototypeText(
                context,
                28,
                family: 'SimSun',
                weight: FontWeight.w500,
              ).copyWith(letterSpacing: .5),
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
                    'A',
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
                  'Agent',
                  style: prototypeText(context, 13, weight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  '来源未记录',
                  style: prototypeText(context, 12, color: c.muted),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Tooltip(
                    message: request.id,
                    child: Text(
                      '${request.id.length > 12 ? '${request.id.substring(0, 8)}…' : request.id} · ${_shortTime(request.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: prototypeText(
                        context,
                        11,
                        color: c.muted,
                        family: 'Consolas',
                        height: 1.6,
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
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(request.purpose, style: prototypeText(context, 14, height: 1.9)),
          SizedBox(height: largeType ? 4 : 6),
          const PrototypeSelfDescription(),
          if (pending &&
              groups.values
                  .expand((refs) => refs)
                  .any((ref) => _currentField(ref)?.kind == FieldKind.file))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '批准文件字段后，Agent 可领取并读取原文件，不只是查看文件名称。',
                style: prototypeText(context, 12, color: c.muted, height: 1.85),
              ),
            ),
          if (pending)
            Padding(
              padding: EdgeInsets.only(top: largeType ? 6 : 18),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _adjustScope(request, selected),
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    background: c.paper,
                    side: BorderSide(color: c.line),
                    radius: 5,
                  ),
                  child: const Text('调整提供范围 / 补选其他信息'),
                ),
              ),
            ),
          SizedBox(height: largeType ? 6 : 20),
          Divider(height: 1, color: c.line),
          SizedBox(height: largeType ? 6 : 16),
          Row(
            children: [
              Text(
                '申请范围',
                style: prototypeText(context, 16, weight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${groups.length} 条信息 / ${groups.values.fold<int>(0, (n, f) => n + f.length)} 个字段',
                style: prototypeText(context, 11, color: c.muted),
              ),
            ],
          ),
          for (final group in groups.entries) ...[
            SizedBox(height: largeType ? 8 : 17),
            Builder(
              builder: (context) {
                final item = widget.service.owner.information
                    .where((i) => i.id == group.key)
                    .firstOrNull;
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            directoryPath(
                              widget.service.owner,
                              item?.directoryId,
                            ),
                            style: prototypeText(
                              context,
                              11,
                              color: c.muted,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              PrototypeIcon(
                                PrototypeIconGlyph.folder,
                                color: c.muted,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _itemLabel(group.key),
                                  style: prototypeText(
                                    context,
                                    19,
                                    family: 'SimSun',
                                    weight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '已选 ${group.value.where(selected.contains).length} / ${group.value.length}',
                      style: prototypeText(context, 11, color: c.muted),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            for (final field in group.value)
              _scopeField(field, selected, available, pending: pending),
          ],
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PrototypeIcon(PrototypeIconGlyph.shield, size: 16),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '仅提供所选字段，分类变化不会扩大本次授权。',
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
  }

  Future<void> _adjustScope(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected,
  ) async {
    var search = '';
    var directories = false;
    final c = UiPalette.of(context);
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final items = widget.service.owner.information
              .where(
                (i) => '${i.name} ${i.description}'.toLowerCase().contains(
                  search.toLowerCase(),
                ),
              )
              .toList();
          final measure = TextPainter(
            text: TextSpan(text: '0', style: prototypeText(context, 14)),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          void select(FieldRef ref, bool value) =>
              update(() => value ? selected.add(ref) : selected.remove(ref));
          return BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
            child: Dialog(
              elevation: 0,
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(32),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: 780,
                  maxHeight: MediaQuery.sizeOf(context).height - 64,
                ),
                // The HTML reserves 15px at each of the modal and flow-scroll gutters.
                padding: const EdgeInsets.fromLTRB(32, 28, 47, 34),
                decoration: BoxDecoration(
                  color: c.paper,
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33211a26),
                      offset: Offset(0, 20),
                      blurRadius: 80,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '调整提供范围',
                            style: prototypeText(
                              context,
                              23,
                              family: 'SimSun',
                              weight: FontWeight.w500,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: TextButton(
                            autofocus: true,
                            style: prototypeButton(
                              context,
                              size: 22,
                              iconOnly: true,
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: const Text(
                              '×',
                              textScaler: TextScaler.noScaling,
                              semanticsLabel: '关闭',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: ListView(
                        primary: false,
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(right: 15, bottom: 16),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: measure.width * 48,
                              ),
                              child: Text(
                                '申请范围与最终提供范围分别保存。你可以取消申请字段，或补选其他信息的字段。',
                                style: prototypeText(
                                  context,
                                  14,
                                  color: c.muted,
                                  height: 1.85,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 15),
                          Text('搜索信息', style: prototypeText(context, 13)),
                          const SizedBox(height: 7),
                          TextField(
                            key: const ValueKey('scope-search'),
                            style: prototypeText(context, 13),
                            decoration: InputDecoration(
                              hintText: '搜索名称或说明',
                              fillColor: c.paper,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 9,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(4),
                                borderSide: BorderSide(color: c.line),
                              ),
                            ),
                            onChanged: (v) => update(() => search = v),
                          ),
                          for (final item in items) ...[
                            // Flutter rounds each 19.5px line box to 20px.
                            SizedBox(height: item == items.first ? 18 : 17),
                            Text(
                              item.name,
                              style: prototypeText(
                                context,
                                16,
                                weight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (final f in item.fields)
                              Builder(
                                builder: (context) {
                                  final ref = FieldRef(item.id, f.id);
                                  return Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      key: ValueKey('scope-field-${f.id}'),
                                      onTap: () =>
                                          select(ref, !selected.contains(ref)),
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          top: f == item.fields.first ? 0 : 8,
                                        ),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: PrototypeCheck(
                                                value: selected.contains(ref),
                                                onChanged: (v) =>
                                                    select(ref, v == true),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                f.name,
                                                style: prototypeText(
                                                  context,
                                                  13,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              request.fields.contains(ref)
                                                  ? '原申请'
                                                  : '用户补选',
                                              style: prototypeText(
                                                context,
                                                12,
                                                color: c.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () =>
                                  update(() => directories = !directories),
                              style: prototypeButton(
                                context,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                foreground: c.strong,
                              ),
                              child: const Text('按目录批量选择'),
                            ),
                          ),
                          if (directories)
                            for (final directory
                                in widget.service.owner.directories)
                              Builder(
                                builder: (context) {
                                  final fields = widget.service.owner
                                      .fieldsInDirectory(directory.id);
                                  final all =
                                      fields.isNotEmpty &&
                                      fields.every(selected.contains);
                                  return TextButton(
                                    key: ValueKey(
                                      'directory-${request.id}-${directory.id}',
                                    ),
                                    onPressed: fields.isEmpty
                                        ? null
                                        : () => update(() {
                                            all
                                                ? selected.removeAll(fields)
                                                : selected.addAll(fields);
                                          }),
                                    style: prototypeButton(
                                      context,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        PrototypeCheck(
                                          value: all,
                                          onChanged: fields.isEmpty
                                              ? null
                                              : (v) => update(() {
                                                  v == true
                                                      ? selected.addAll(fields)
                                                      : selected.removeAll(
                                                          fields,
                                                        );
                                                }),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '按目录选择：${directoryPath(widget.service.owner, directory.id)}',
                                          ),
                                        ),
                                        Text(
                                          '${fields.where(selected.contains).length} / ${fields.length}',
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.only(top: 16),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.line)),
                      ),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          key: const ValueKey('scope-apply'),
                          style: prototypeButton(
                            context,
                            size: 13,
                            weight: FontWeight.w600,
                            foreground: Colors.white,
                            background: c.accent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 21,
                              vertical: 10.5,
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('使用这'),
                              const SizedBox(width: 16),
                              Text('${selected.length}'),
                              const SizedBox(width: 16),
                              const Text('个字段'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (mounted) setState(() => _actionError = null);
  }

  String _shortTime(DateTime value) {
    final d = value.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _decision(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected, {
    required bool compact,
  }) {
    if (compact) return _legacyDecision(request, selected, compact: true);
    final c = UiPalette.of(context);
    final pending = request.state == AccessRequestState.pending;
    final busy =
        _busy.contains(request.id) || !widget.service.owner.serviceAvailable;
    final minutes = pending
        ? (_grantMinutes[request.id] ?? 480)
        : (request.grantLifetime?.inMinutes ??
              _grantMinutes[request.id] ??
              480);
    final Iterable<FieldRef> refs = pending
        ? selected
        : (request.approvedFields ?? <FieldRef>[]);
    final reviewedVersions = _reviewedVersions(refs);
    final omissions = request.fields.where((f) => !refs.contains(f)).length;
    final extra = refs.where((f) => !request.fields.contains(f)).length;
    return Container(
      key: ValueKey('decision-${request.id}'),

      decoration: BoxDecoration(
        color: c.rail,
        border: Border(left: BorderSide(color: c.line)),
      ),
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
              '提供哪些信息',
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
                  '${refs.length}',
                  style: prototypeText(
                    context,
                    48,
                    family: 'Georgia',
                    height: 1.2,
                    color: c.strong,
                  ),
                ),
                const SizedBox(width: 11),
                Text('个字段', style: prototypeText(context, 12, color: c.muted)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '原申请 $omissions 个字段不提供；补选 $extra 个字段',
              style: prototypeText(context, 11, color: c.muted),
            ),
            const SizedBox(height: 22),
            Divider(height: 1, color: c.line),
            const SizedBox(height: 21),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: Scrollbar(
                controller: _scopeScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  primary: false,
                  controller: _scopeScroll,
                  child: refs.isEmpty
                      ? Text(
                          '尚未选择字段',
                          style: prototypeText(context, 12, color: c.muted),
                        )
                      : _scopeSummary(refs),
                ),
              ),
            ),
            const SizedBox(height: 29),
            Text('授权期限', style: prototypeText(context, 12)),
            const SizedBox(height: 9),
            Transform.translate(
              offset: const Offset(0, -1),
              child: Container(
                height: 41,
                padding: const EdgeInsets.only(left: 14, right: 6),
                decoration: BoxDecoration(
                  color: c.paper,
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: DesktopSelect<int>(
                  key: ValueKey('grant-lifetime-${request.id}'),
                  isExpanded: true,
                  value: minutes,
                  items: [
                    for (final n in {15, 30, 60, 480, minutes})
                      DropdownMenuItem(
                        value: n,
                        child: Text(n == 480 ? '8 小时（默认）' : _durationLabel(n)),
                      ),
                    const DropdownMenuItem(value: -1, child: Text('自定义…')),
                  ],
                  onChanged: busy || !pending
                      ? null
                      : (n) async {
                          if (n == null) return;
                          if (n == -1) {
                            await _customLifetime(request.id, minutes);
                          } else {
                            setState(() => _grantMinutes[request.id] = n);
                          }
                        },
                ),
              ),
            ),
            if (pending) ...[
              const SizedBox(height: 23),
              FilledButton(
                key: const ValueKey('approve-selection'),
                onPressed:
                    busy ||
                        selected.isEmpty ||
                        minutes < 1 ||
                        minutes > 10080 ||
                        !_filesReady(selected)
                    ? null
                    : () => _manage(
                        () => widget.service.owner.approve(
                          request.id,
                          selected.toList(),
                          lifetime: Duration(minutes: minutes),
                          reviewedVersions: reviewedVersions,
                        ),
                      ),
                style: prototypeButton(
                  context,
                  size: 13,
                  foreground: Colors.white,
                  background: c.accent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12.5,
                  ),
                  side: BorderSide(color: c.accent),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _busy.contains(request.id) ? '正在保存…' : '批准所选字段',
                      style: prototypeText(
                        context,
                        13,
                        color: Colors.white,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Text('→'),
                  ],
                ),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () =>
                          _manage(() => widget.service.owner.deny(request.id)),
                style: prototypeButton(
                  context,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  foreground: c.ink,
                ),
                child: const Text('拒绝请求'),
              ),
            ] else ...[
              const SizedBox(height: 19),
              Divider(height: 1, color: c.line),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PrototypeIcon(PrototypeIconGlyph.clock, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '此请求已处理。\n当前授权状态请查看授权历史。',
                      style: prototypeText(context, 12, color: c.muted),
                    ),
                  ),
                ],
              ),
              if (request.sessionEnded)
                const QuietNotice('聊天已结束。恢复聊天需要重新连接并申请授权。'),
              if (request.state == AccessRequestState.approved)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _manage(
                          () => widget.service.owner.revoke(request.id),
                        ),
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    foreground: c.strong,
                  ),
                  child: const Text('撤销授权'),
                ),
            ],
            if (_actionError != null) QuietNotice(_actionError!, warning: true),
            const SizedBox(height: 16),
            Text(
              '仅本次会话有效。\n会话结束或到期后失效。',
              style: prototypeText(context, 11, color: c.muted, height: 1.9),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _customLifetime(String id, int minutes) async {
    var draft = '$minutes';
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final n = int.tryParse(draft);
          final valid = n != null && n >= 1 && n <= 10080;
          return PrototypeDialog(
            title: '自定义授权期限',
            onClose: () => Navigator.pop(context),
            body: DesktopTextFormField(
              initialValue: draft,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '授权期限（分钟）',
                helperText: '1 至 10080 分钟',
                errorText: valid ? null : '请输入 1 至 10080 的整数',
              ),
              onChanged: (v) => update(() => draft = v),
            ),
            actions: [
              TextButton(
                style: prototypeSecondary(context),
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                style: prototypePrimary(context),
                onPressed: !valid
                    ? null
                    : () {
                        setState(() => _grantMinutes[id] = n);
                        Navigator.pop(context);
                      },
                child: const Text('保存期限'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _scopeSummary(Iterable<FieldRef> refs) {
    final c = UiPalette.of(context);
    final groups = <String, List<FieldRef>>{};
    for (final ref in refs) {
      groups.putIfAbsent(ref.itemId, () => []).add(ref);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups.entries) ...[
          if (group.key != groups.keys.first) const SizedBox(height: 15),
          Text(
            _itemLabel(group.key),
            style: prototypeText(
              context,
              13,
              weight: FontWeight.w700,
              height: 21 / 13,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            group.value.map(_scopeName).join('、'),
            style: prototypeText(context, 12, color: c.muted, height: 1.8),
          ),
        ],
      ],
    );
  }

  Widget _legacyDecision(
    OwnerRequestSnapshot request,
    Set<FieldRef> selected, {
    required bool compact,
  }) {
    final pending = request.state == AccessRequestState.pending;
    final busy =
        _busy.contains(request.id) || !widget.service.owner.serviceAvailable;
    final minutes = _grantMinutes[request.id] ?? 480;
    final valid = minutes >= 1 && minutes <= 10080;
    final reviewedVersions = _reviewedVersions(selected);
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
          child: const Text('拒绝请求'),
        ),
        FilledButton.icon(
          key: const ValueKey('approve-selection'),
          onPressed:
              busy || selected.isEmpty || !valid || !_filesReady(selected)
              ? null
              : () => _manage(
                  () => widget.service.owner.approve(
                    request.id,
                    selected.toList(),
                    lifetime: Duration(minutes: minutes),
                    reviewedVersions: reviewedVersions,
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
                    primary: false,
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
                        barrierColor: const Color(0x4f241b27),
                        builder: (context) => PrototypeDialog(
                          title: '本次授权范围 · ${selected.length} 个字段',
                          flow: true,
                          onClose: () => Navigator.pop(context),
                          body: SizedBox(
                            height: 420,
                            child: SingleChildScrollView(
                              primary: false,
                              child: _scopeGroups(selected),
                            ),
                          ),
                          actions: [
                            TextButton(
                              style: prototypeSecondary(context),
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
                      primary: false,
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
              _itemLabel(group.key),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final ref in group.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Text('· ${_scopeName(ref)}'),
            ),
        ],
      ],
    );
  }

  Widget _scopeField(
    FieldRef ref,
    Set<FieldRef> selected,
    Set<FieldRef> available, {
    bool pending = true,
  }) {
    final c = UiPalette.of(context);
    final item = widget.service.owner.information
        .where((i) => i.id == ref.itemId)
        .firstOrNull;
    final field = item?.fields.where((f) => f.id == ref.fieldId).firstOrNull;
    final focusedRequest = _focused;
    final chosen = selected.contains(ref);
    final large = MediaQuery.textScalerOf(context).scale(14) > 20;
    final ValueChanged<bool?>? change =
        !pending ||
            _busy.contains(_focused) ||
            !widget.service.owner.serviceAvailable
        ? null
        : (value) => setState(() {
            value == true ? selected.add(ref) : selected.remove(ref);
            _actionError = null;
          });
    final value = field?.kind == FieldKind.file && available.contains(ref)
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: InformationFileSummary(
              key: ValueKey('approval-file-$focusedRequest-${ref.fieldId}'),
              owner: widget.service.owner,
              reference: field!.attachment!,
              compact: true,
              onLoaded: (version) {
                if (version.available &&
                    mounted &&
                    focusedRequest != null &&
                    _focused == focusedRequest &&
                    _loadedFiles
                        .putIfAbsent(focusedRequest, () => {})
                        .add(version.reference)) {
                  setState(() {});
                }
              },
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                !available.contains(ref)
                    ? pending
                          ? '字段已不可用，可取消选择'
                          : '原字段已移除，旧授权不可读取'
                    : field?.value ?? '不可用',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: prototypeText(
                  context,
                  12,
                  family: 'Consolas',
                  color: chosen ? c.ink : c.muted,
                  height: 1.6,
                ),
              ),
              if (field != null &&
                  field.kind != FieldKind.file &&
                  (field.value.length > 200 || field.value.contains('\n')))
                TextButton(
                  style: prototypeButton(context),
                  onPressed: () => showDialog<void>(
                    context: context,
                    barrierColor: const Color(0x4f241b27),
                    builder: (context) => PrototypeDialog(
                      title: '查看完整字段值',
                      flow: true,
                      onClose: () => Navigator.pop(context),
                      body: SizedBox(
                        height: 420,
                        child: SingleChildScrollView(
                          primary: false,
                          child: SelectableText(
                            field.value,
                            style: prototypeText(
                              context,
                              13,
                              family: 'Consolas',
                              height: 1.7,
                            ),
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          style: prototypeSecondary(context),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('返回审批'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('查看完整值'),
                ),
            ],
          );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('field-${ref.fieldId}'),
        onTap: change == null ? null : () => change(!chosen),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.line)),
          ),
          child: Row(
            children: [
              PrototypeCheck(value: chosen, onChanged: change),
              const SizedBox(width: 10),
              if (large)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          field?.name ?? _fieldLabel(ref),
                          style: prototypeText(context, 13),
                        ),
                        value,
                      ],
                    ),
                  ),
                )
              else ...[
                SizedBox(
                  width: 98,
                  child: Text(
                    field?.name ?? _fieldLabel(ref),
                    style: prototypeText(context, 13),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: value),
                const SizedBox(width: 10),
              ],
              SizedBox(
                width: 38,
                child: Text(
                  chosen ? '提供' : '不提供',
                  textAlign: TextAlign.right,
                  style: prototypeText(context, 11, color: c.muted),
                ),
              ),
            ],
          ),
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
    return _recordedField(ref)?.fieldName ?? '字段名称未记录';
  }

  String _durationLabel(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final remaining = minutes % 60;
    return remaining == 0 ? '$hours 小时' : '$hours 小时 $remaining 分钟';
  }

  String _state(AccessRequestState state) => switch (state) {
    AccessRequestState.pending => '待处理',
    AccessRequestState.approved => '已批准',
    AccessRequestState.revoked => '已撤销',
    AccessRequestState.denied => '已拒绝',
    AccessRequestState.cancelled => '已取消',
    AccessRequestState.expired => '已过期',
  };
}
