import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'settings.dart';
import 'backups.dart';

class AuthorizationHistory extends StatefulWidget {
  const AuthorizationHistory({
    super.key,
    required this.owner,
    this.onOpenRecordSettings,
    this.initialRecordId,
  });
  final OwnerAccess owner;
  final VoidCallback? onOpenRecordSettings;

  /// Selects an existing fact only; an absent ID never creates authorization.
  final String? initialRecordId;
  @override
  State<AuthorizationHistory> createState() => _AuthorizationHistoryState();
}

class _HistoryEntry {
  _HistoryEntry({
    required this.id,
    required this.title,
    required this.chat,
    required this.at,
    this.until,
    this.grant,
    this.request,
    this.organization,
    this.orphan,
  });
  final String id, title, chat;
  final DateTime at;
  final DateTime? until;
  final GrantHistory? grant;
  final RequestHistory? request;
  final OrganizationTask? organization;
  final AccessRecord? orphan;
  bool get active => grant?.active ?? false;
  List<RecordedField> get fields =>
      grant?.fields ?? request?.fields ?? const [];
}

class _AuthorizationHistoryState extends State<AuthorizationHistory> {
  late Future<AuditHistory> _history;
  final _search = TextEditingController();
  final _scrolls = <String, ScrollController>{};
  String? _selected, _error;
  int _filter = 0, _page = 0, _tab = 0;
  bool _busy = false;
  bool _focusPending = true;
  @override
  void initState() {
    super.initState();
    _history = widget.owner.history();
  }

  @override
  void didUpdateWidget(AuthorizationHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRecordId != widget.initialRecordId) {
      _focusPending = true;
      _search.clear();
      _filter = 0;
      _tab = 0;
      _history = widget.owner.history();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    for (final c in _scrolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _reload() => setState(() => _history = widget.owner.history());
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) _reload();
    } catch (_) {
      if (mounted) setState(() => _error = '记录未能保存，已有决定保持不变。请修复存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<_HistoryEntry> _entries(AuditHistory history) {
    final requests = {for (final r in history.requests) r.id: r};
    final grants = {for (final g in history.grants) g.id: g};
    final list = <_HistoryEntry>[
      for (final grant in history.grants)
        _HistoryEntry(
          id: grant.id,
          title: requests[grant.requestId]?.purpose ?? '未记录用途',
          chat: grant.chatLabel,
          at: grant.approvedAt,
          until: grant.expiresAt,
          grant: grant,
          request: requests[grant.requestId],
        ),
      for (final r in history.requests.where(
        (r) => !grants.containsKey(r.grantId),
      ))
        _HistoryEntry(
          id: r.id,
          title: r.purpose,
          chat: r.chatLabel,
          at: r.createdAt,
          until: r.requestExpiresAt,
          request: r,
        ),
      for (final task in history.organizations)
        _HistoryEntry(
          id: task.id,
          title: task.purpose,
          chat: task.chatLabel,
          at: task.approvedAt ?? task.createdAt,
          until: task.expiresAt,
          organization: task,
        ),
      for (final r in history.accesses.where(
        (r) => !grants.containsKey(r.grantId),
      ))
        _HistoryEntry(
          id: r.id,
          title: '未关联保留中授权的读取尝试',
          chat: '未记录会话名称',
          at: r.at,
          orphan: r,
        ),
    ];
    list.sort((a, b) {
      final time = b.at.compareTo(a.at);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
    return list;
  }

  String _state(_HistoryEntry e) {
    if (e.grant case final g?) {
      if (g.restoredAt != null) return '历史事实';
      return switch (g.events.last.kind) {
        GrantEventKind.approved => '有效',
        GrantEventKind.revoked => '已撤销',
        GrantEventKind.expired => '已到期',
        GrantEventKind.ended => '已结束',
        GrantEventKind.applicationClosed => '已结束',
      };
    }
    if (e.organization case final t?) {
      return switch (widget.owner.organizationState(t)) {
        OrganizationTaskState.active => '有效',
        OrganizationTaskState.confirmed => '已完成',
        OrganizationTaskState.proposed => '待确认',
        OrganizationTaskState.rejected => '已拒绝',
        OrganizationTaskState.expired => '已到期',
        OrganizationTaskState.conflicted => '冲突',
        _ => '已结束',
      };
    }
    if (e.request case final r?) {
      if (r.restoredAt != null) return '历史事实';
      return switch (r.state) {
        AccessRequestState.denied => '已拒绝',
        AccessRequestState.cancelled => '已取消',
        AccessRequestState.expired => '已到期',
        AccessRequestState.revoked => '已撤销',
        AccessRequestState.approved => '已批准',
        _ => '已结束',
      };
    }
    return '读取被拒绝';
  }

  String _time(DateTime at) {
    final t = at.toLocal();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _text(
    String text,
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
    String? family,
    double height = 1.5,
  }) => Text(
    text,
    style: prototypeText(
      context,
      size,
      color: color,
      weight: weight,
      family: family,
      height: height,
    ),
  );
  int _reads(_HistoryEntry e, AuditHistory history) => e.orphan != null
      ? 1
      : history.accesses
            .where((a) => a.grantId == e.grant?.id && e.grant != null)
            .length;
  Future<void> _settings() async {
    if (widget.onOpenRecordSettings != null) {
      widget.onOpenRecordSettings!();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: SettingsPage(
            owner: widget.owner,
            files: const NativeBackupFilePicker(),
            initialSection: SettingsSection.records,
          ),
        ),
      ),
    );
    if (mounted) _reload();
  }

  Widget _queue(
    List<_HistoryEntry> all,
    List<_HistoryEntry> filtered,
    List<_HistoryEntry> visible,
    AuditHistory history,
  ) {
    final c = UiPalette.of(context);
    return Container(
      width: 310,
      decoration: BoxDecoration(
        color: c.rail,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(21, 28, 21, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _text('授权历史', 21, weight: FontWeight.w700),
                    const Spacer(),
                    _text(
                      '${all.length}',
                      24,
                      color: c.muted,
                      family: 'Georgia',
                      height: 1.2,
                    ),
                  ],
                ),
                const SizedBox(height: 23),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9.5,
                  ),
                  decoration: BoxDecoration(
                    color: c.canvas,
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      PrototypeIcon(PrototypeIconGlyph.search, color: c.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('history-search'),
                          controller: _search,
                          maxLength: 2000,
                          style: prototypeText(context, 13),
                          decoration: InputDecoration(
                            isCollapsed: true,
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            hintText: '搜索聊天、Agent、记录编号',
                            hintStyle: prototypeText(
                              context,
                              13,
                              color: c.muted,
                            ),
                            counterText: '',
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (_) => setState(() {
                            _page = 0;
                            _selected = null;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 21),
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 21),
                      Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _filter == i
                                  ? c.accent
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: TextButton(
                          key: ValueKey('history-filter-$i'),
                          onPressed: () => setState(() {
                            _filter = i;
                            _page = 0;
                            _selected = null;
                          }),
                          style: prototypeButton(
                            context,
                            padding: const EdgeInsets.only(bottom: 12),
                            radius: 0,
                          ),
                          child: _text(
                            ['全部', '有效', '已结束'][i],
                            12,
                            color: _filter == i ? c.strong : c.muted,
                            weight: _filter == i
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(21, 18, 21, 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 4,
              children: [
                _text('按授权时间排列', 12, color: c.muted),
                _text(
                  '最近 ${widget.owner.auditRetentionDays} 天',
                  12,
                  color: c.muted,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        _text('没有找到记录', 16),
                        const SizedBox(height: 10),
                        _text('试试其他关键词或状态。', 13, color: c.muted),
                        TextButton(
                          onPressed: () => setState(() {
                            _search.clear();
                            _filter = 0;
                            _page = 0;
                          }),
                          child: const Text('清除筛选'),
                        ),
                      ],
                    ),
                  ),
                for (final e in visible)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextButton(
                      key: ValueKey('history-entry-${e.id}'),
                      onPressed: () => setState(() {
                        _selected = e.id;
                        _tab = 0;
                      }),
                      style: prototypeButton(
                        context,
                        padding: EdgeInsets.fromLTRB(
                          12,
                          e.id == _selected ? 19 : 19.5,
                          12,
                          0,
                        ),
                        radius: e.id == _selected ? 6 : 0,
                        background: e.id == _selected
                            ? c.selected
                            : Colors.transparent,
                        side: e.id == _selected
                            ? BorderSide(
                                color: Color.lerp(c.line, c.accent, .3)!,
                              )
                            : BorderSide.none,
                      ),
                      child: Container(
                        padding: EdgeInsets.only(
                          bottom: e.id == _selected ? 19 : 19.5,
                        ),
                        decoration: BoxDecoration(
                          border: e.id == _selected
                              ? null
                              : Border(bottom: BorderSide(color: c.line)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: prototypeText(
                                      context,
                                      14,
                                      weight: FontWeight.w700,
                                      height: 1.6,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                _text(
                                  _time(e.at),
                                  11,
                                  color: c.muted,
                                  family: 'Consolas',
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: _text(
                                    '${e.chat} · ${e.organization != null ? '整理资料' : '${_reads(e, history)} 次访问'}',
                                    12,
                                    color: c.muted,
                                  ),
                                ),
                                _text(
                                  _state(e),
                                  12,
                                  color: _state(e) == '有效'
                                      ? c.statusLive
                                      : c.muted,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                _text('${filtered.length} 条记录', 12, color: c.muted),
                const Spacer(),
                SizedBox(
                  width: 24,
                  height: 25 * MediaQuery.textScalerOf(context).scale(12) / 12,
                  child: TextButton(
                    onPressed: _page == 0
                        ? null
                        : () => setState(() {
                            _page--;
                            _selected = null;
                          }),
                    style: prototypeButton(context, size: 18),
                    child: Transform.translate(
                      offset: const Offset(0, 3),
                      child: _text(
                        '‹',
                        20,
                        height: 1.2,
                        color: _page == 0
                            ? c.muted.withValues(alpha: .45)
                            : c.muted,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 38 * MediaQuery.textScalerOf(context).scale(12) / 12,
                  child: Transform.translate(
                    offset: const Offset(0, -1),
                    child: Center(
                      child: _text(
                        '${_page + 1} / ${math.max(1, (filtered.length / 8).ceil())}',
                        12,
                        color: c.muted,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 25 * MediaQuery.textScalerOf(context).scale(12) / 12,
                  child: TextButton(
                    onPressed: (_page + 1) * 8 >= filtered.length
                        ? null
                        : () => setState(() {
                            _page++;
                            _selected = null;
                          }),
                    style: prototypeButton(context, size: 18),
                    child: Transform.translate(
                      offset: const Offset(0, 3),
                      child: _text(
                        '›',
                        20,
                        height: 1.2,
                        color: (_page + 1) * 8 >= filtered.length
                            ? c.muted.withValues(alpha: .45)
                            : c.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(_HistoryEntry e) {
    final c = UiPalette.of(context);
    final cells = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _text(
            e.grant != null || e.organization != null ? '批准范围' : '申请范围',
            12,
            color: c.muted,
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              _text(
                '${e.organization?.itemVersions.length ?? e.fields.length}',
                28,
                color: c.strong,
                family: 'Georgia',
                height: 1.2,
              ),
              const SizedBox(width: 5),
              _text(e.organization == null ? '个字段' : '条信息的元数据', 15),
            ],
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _text(
            e.grant != null || e.organization?.approvedAt != null
                ? '授权时间'
                : '申请时间',
            12,
            color: c.muted,
          ),
          const SizedBox(height: 8),
          _text(_time(e.at), 15, weight: FontWeight.w500),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _text('到期时间', 12, color: c.muted),
          const SizedBox(height: 8),
          _text(
            e.until == null ? '未记录' : _time(e.until!),
            15,
            weight: FontWeight.w500,
          ),
        ],
      ),
    ];
    return Container(
      margin: const EdgeInsets.only(top: 28),
      padding: const EdgeInsets.only(top: 20, bottom: 18),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: c.line),
          bottom: BorderSide(color: c.line),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: Container(
                  padding: EdgeInsets.only(left: i == 0 ? 0 : 24),
                  decoration: i == 0
                      ? null
                      : BoxDecoration(
                          border: Border(left: BorderSide(color: c.line)),
                        ),
                  child: cells[i],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _scope(_HistoryEntry e) {
    final c = UiPalette.of(context), groups = <String, List<RecordedField>>{};
    for (final f in e.fields) {
      groups.putIfAbsent(f.itemId, () => []).add(f);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final fields in groups.values)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20.5),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 38,
                  decoration: BoxDecoration(
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: PrototypeIcon(
                      PrototypeIconGlyph.file,
                      color: c.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _text(fields.first.itemName, 15, weight: FontWeight.w700),
                      const SizedBox(height: 7),
                      _text(
                        fields.map((f) => f.fieldName).join('、'),
                        13,
                        color: c.muted,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: _text(
                    e.grant == null ? '未授予读取' : '可读取',
                    11,
                    color: c.muted,
                  ),
                ),
              ],
            ),
          ),
        if (e.organization case final task?) ...[
          for (final id in task.itemVersions.keys)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20.5),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Row(
                children: [
                  const PrototypeIcon(PrototypeIconGlyph.file),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _text(
                      task.itemNames[id] ?? '信息名称未记录',
                      15,
                      weight: FontWeight.w700,
                    ),
                  ),
                  _text('可整理元数据', 11, color: c.muted),
                ],
              ),
            ),
        ],
        if (e.fields.isEmpty && e.organization == null)
          _text('原范围未记录，无法从当前资料推断。', 13, color: c.muted),
        const SettingsNotice(
          '记录范围，不记录内容',
          '这里不保留字段值、访问凭据或密钥。目录调整不会让授权范围随之扩大。',
          verticalPadding: 15.5,
          textOffset: -1,
          lineGap: 2,
        ),
      ],
    );
  }

  Widget _event(String title, String detail, DateTime at, {String? outcome}) {
    final c = UiPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.fromLTRB(28, 0, 0, 27),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _text(title, 14, weight: FontWeight.w700)),
              _text(_time(at), 12, color: c.muted),
            ],
          ),
          const SizedBox(height: 8),
          _text(detail, 13, color: c.muted),
          if (outcome != null) ...[
            const SizedBox(height: 8),
            _text(
              outcome,
              13,
              color: outcome == '访问允许' ? c.statusLive : c.statusAttention,
            ),
          ],
        ],
      ),
    );
  }

  Widget _accesses(_HistoryEntry e, AuditHistory history) {
    final records =
        e.orphan != null
              ? [e.orphan!]
              : history.accesses
                    .where((r) => e.grant != null && r.grantId == e.grant!.id)
                    .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    return Padding(
      padding: const EdgeInsets.only(top: 23),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in records)
            _event(
              '读取信息字段',
              () {
                final f = e.fields
                    .where(
                      (f) => f.itemId == r.itemId && f.fieldId == r.fieldId,
                    )
                    .firstOrNull;
                return f == null
                    ? '${r.itemName ?? '信息名称未记录'}：${r.fieldName ?? '字段名称未记录'}'
                    : '${f.itemName}：${f.fieldName}';
              }(),
              r.at,
              outcome: switch (r.outcome) {
                AccessOutcome.allowed => '访问允许',
                AccessOutcome.unauthorized => '读取被拒绝',
                AccessOutcome.auditUnavailable => '记录保存异常，未提供内容',
              },
            ),
          if (e.grant case final g?)
            for (final event in g.events.reversed)
              _event(
                switch (event.kind) {
                  GrantEventKind.approved => '用户批准授权',
                  GrantEventKind.revoked => '用户撤销授权',
                  GrantEventKind.expired => '授权已到期',
                  GrantEventKind.ended => '会话已结束',
                  GrantEventKind.applicationClosed => '应用运行已结束',
                },
                event.kind == GrantEventKind.approved
                    ? '限本次会话使用，至 ${_time(g.expiresAt)} 失效。'
                    : '后续读取不再获准。',
                event.at,
              ),
          if (records.isEmpty && e.grant == null)
            _text(
              '没有已记录的实际读取。批准范围不表示已经访问。',
              13,
              color: UiPalette.of(context).muted,
            ),
        ],
      ),
    );
  }

  Widget _result(_HistoryEntry e) {
    final task = e.organization!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 23),
        _text('整理结果 · ${_state(e)}', 17, weight: FontWeight.w700),
        const SizedBox(height: 14),
        if (task.changes.isEmpty)
          _text('本次没有已提交的分类或标签变更。', 13, color: UiPalette.of(context).muted),
        for (final change in task.changes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _text(
                  '${task.itemNames[change.itemId] ?? '信息名称未记录'} · 版本 ${change.baseVersion}',
                  14,
                ),
                _text(
                  '目录：${change.directoryName.isEmpty ? change.directoryId ?? '未分类' : change.directoryName}；标签：${change.tagNames.isEmpty ? '未记录名称' : change.tagNames.join('、')}',
                  13,
                  color: UiPalette.of(context).muted,
                ),
              ],
            ),
          ),
        const SettingsNotice(
          '只整理分类与标签',
          '此结果不包含字段值修改。当前整理模型未保存元数据访问事件，不能据此推断实际读取次数。',
        ),
      ],
    );
  }

  Future<void> _revoke(_HistoryEntry e) async {
    final confirm = await showSettingsDialog<bool>(
      context: context,
      builder: (context) => SettingsDialog(
        title: '撤销当前授权',
        actions: [
          settingsAction(context, '保留授权', () => Navigator.pop(context, false)),
          settingsAction(
            context,
            '确认撤销',
            () => Navigator.pop(context, true),
            primary: true,
          ),
        ],
        child: Text(
          '将停止「${e.title}」的后续读取。已经提供的内容无法收回。',
          style: prototypeText(
            context,
            14,
            height: 1.9,
            color: UiPalette.of(context).muted,
          ),
        ),
      ),
    );
    if (confirm == true) {
      await _run(() => widget.owner.revokeFromHistory(e.grant!.id));
    }
  }

  Widget _document(_HistoryEntry e, AuditHistory history) {
    final c = UiPalette.of(context);
    final scroll = _scrolls.putIfAbsent(
      '${e.id}-$_tab',
      () => ScrollController(),
    );
    return Container(
      key: ValueKey('history-document-${e.id}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.paper,
        border: Border.all(color: c.line),
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
            child: Scrollbar(
              controller: scroll,
              child: SingleChildScrollView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(34, 28, 42, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _text(
                          e.active ? '● 授权有效' : _state(e),
                          12,
                          color: e.active ? c.statusLive : c.muted,
                        ),
                        const SizedBox(width: 12),
                        _text(
                          e.organization != null
                              ? '整理资料'
                              : e.grant != null
                              ? '读取信息'
                              : '访问请求',
                          12,
                        ),
                        const Spacer(),
                        _text(
                          e.id.length > 20 ? '${e.id.substring(0, 16)}…' : e.id,
                          12,
                          family: 'Consolas',
                          color: c.muted,
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 13, bottom: 16),
                      child: Text(
                        e.title,
                        style: prototypeText(
                          context,
                          29,
                          family: 'SimSun',
                          weight: FontWeight.w500,
                        ),
                      ),
                    ),
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
                          child: _text(
                            e.chat.isEmpty ? 'A' : e.chat.substring(0, 1),
                            16,
                            family: 'Georgia',
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: _text(e.chat, 14, weight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        _text('申请时的会话', 12, color: c.muted),
                      ],
                    ),
                    if (e.grant?.restoredAt != null ||
                        e.request?.restoredAt != null)
                      const SettingsNotice(
                        '从备份恢复的历史记录',
                        '只保留曾经授权的事实，这条记录不赋予当前访问权限。',
                        icon: PrototypeIconGlyph.clock,
                      ),
                    _summary(e),
                    Container(
                      margin: const EdgeInsets.only(top: 23),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.line)),
                      ),
                      child: Row(
                        children: [
                          for (
                            var i = 0;
                            i < (e.organization == null ? 2 : 3);
                            i++
                          ) ...[
                            if (i > 0) const SizedBox(width: 28),
                            Container(
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: _tab == i
                                        ? c.accent
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                              child: TextButton(
                                onPressed: () => setState(() => _tab = i),
                                style: prototypeButton(
                                  context,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 13,
                                  ),
                                  size: 14,
                                  radius: 0,
                                ),
                                child: _text(
                                  i == 0
                                      ? (e.grant != null ||
                                                e.organization != null
                                            ? '批准范围'
                                            : '申请范围')
                                      : i == 1
                                      ? e.organization == null
                                            ? '实际访问 ${_reads(e, history)}'
                                            : '实际访问 未记录'
                                      : '整理结果',
                                  14,
                                  color: _tab == i ? c.strong : c.muted,
                                  weight: _tab == i
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_tab == 0)
                      _scope(e)
                    else if (_tab == 1)
                      _accesses(e, history)
                    else
                      _result(e),
                    if (_error != null)
                      SettingsNotice('记录保存异常', _error!, error: true),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
            decoration: BoxDecoration(
              color: c.rail,
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _text(
                    e.active
                        ? '撤销会阻止后续读取，已经提供的内容无法收回。'
                        : '这条记录只表示过去事实，不会重新授予访问能力。',
                    12,
                    color: c.muted,
                    height: 1.8,
                  ),
                ),
                if (e.active)
                  SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(13) > 19.5
                        ? null
                        : 41,
                    child: settingsAction(
                      context,
                      '撤销授权',
                      _busy ? null : () => _revoke(e),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AuditHistory>(
    future: _history,
    builder: (context, snapshot) {
      final c = UiPalette.of(context);
      if (snapshot.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SettingsNotice(
                '授权历史暂不可用',
                '记录保存异常时信息读取已暂停。修复存储后重试保存。',
                error: true,
              ),
              const SizedBox(height: 20),
              settingsAction(
                context,
                '重试保存记录',
                _busy ? null : () => _run(widget.owner.retryAuditStorage),
              ),
            ],
          ),
        );
      }
      if (snapshot.data == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final history = snapshot.data!,
          all = _entries(history),
          needle = _search.text.trim().toLowerCase();
      if (_focusPending) {
        _focusPending = false;
        final index = all.indexWhere((e) => e.id == widget.initialRecordId);
        if (index >= 0) {
          _page = index ~/ 8;
          _selected = all[index].id;
        }
      }
      final filtered = all
          .where(
            (e) =>
                (_filter == 0 ||
                    (_filter == 1 ? _state(e) == '有效' : _state(e) != '有效')) &&
                (needle.isEmpty ||
                    [
                      e.id,
                      e.title,
                      e.chat,
                      ...e.fields.map((f) => '${f.itemName} ${f.fieldName}'),
                    ].any((s) => s.toLowerCase().contains(needle))),
          )
          .toList();
      _page = math.min(_page, math.max(0, ((filtered.length - 1) / 8).floor()));
      final visible = filtered.skip(_page * 8).take(8).toList();
      if (!visible.any((e) => e.id == _selected)) {
        _selected = visible.firstOrNull?.id;
        _tab = 0;
      }
      final selected = visible.where((e) => e.id == _selected).firstOrNull;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _queue(all, filtered, visible, history),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 23, 28, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 34),
                    child: Row(
                      children: [
                        _text('授权历史', 12, color: c.muted),
                        const SizedBox(width: 11),
                        PrototypeIcon(
                          PrototypeIconGlyph.chev,
                          size: 13,
                          color: c.muted,
                        ),
                        const SizedBox(width: 11),
                        _text('授权与访问记录', 12),
                        const Spacer(),
                        TextButton(
                          onPressed: _settings,
                          style: prototypeButton(
                            context,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            background: c.paper,
                            side: BorderSide(color: c.line),
                            radius: 5,
                          ),
                          child: Row(
                            children: [
                              PrototypeIcon(
                                PrototypeIconGlyph.tune,
                                size: 15,
                                color: c.muted,
                              ),
                              const SizedBox(width: 8),
                              _text('记录保留设置', 12, color: c.muted),
                            ],
                          ),
                        ),
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
                                _text(all.isEmpty ? '暂无授权历史。' : '没有匹配的内容', 18),
                                const SizedBox(height: 10),
                                _text('调整左侧搜索或筛选后，继续查看详情。', 14, color: c.muted),
                              ],
                            ),
                          )
                        : _document(selected, history),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
