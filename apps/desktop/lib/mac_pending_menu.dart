import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:info_core/access_timing.dart';

import 'ui_palette.dart';
import 'workspace/workspace_source.dart';

/// Owner-process projection for the native menu. Review tokens and commands
/// stay in Dart, and the service remains responsible for every decision.
class MacPendingMenu {
  MacPendingMenu({
    required this.publish,
    required this.open,
    required this.canAct,
    required this.theme,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<void> Function(Map<String, Object?>) publish;
  final Future<void> Function(WorkspacePage, String?) open;
  final bool Function() canAct;
  final WorkspaceTheme Function() theme;
  final DateTime Function() _clock;
  WorkspaceSource? _source;
  String _location = '未连接服务器';
  bool _offline = false, _again = false, _busy = false, _closed = false;
  int _binding = 0, _presentation = 0, _connectionRevision = 0;
  String? _publishedContent;
  Future<void>? _reading;
  Timer? _expiry;
  String? _notice;
  final _displayed = <String, WorkspaceApprovalDetail>{};
  WorkspaceApprovalChange? _uncertain;
  Future<void>? _action;
  Future<void> get idle async {
    await _action;
    await _reading;
  }

  void bind(WorkspaceSource? source, {String location = '未连接服务器'}) {
    _binding++;
    _source = source;
    _location = location;
    _offline = false;
    _displayed.clear();
    _uncertain = null;
    _notice = null;
    _busy = false;
    _expiry?.cancel();
    unawaited(_send(_payload(source == null ? location : '正在读取待办…')));
    unawaited(refresh());
  }

  void setOffline(bool offline) {
    if (_offline == offline) return;
    _offline = offline;
    _connectionRevision++;
    if (offline) {
      _displayed.clear();
      _expiry?.cancel();
      unawaited(_send(_payload('连接已断开')));
    } else {
      unawaited(refresh());
    }
  }

  void setLocation(String location) => _location = location;

  Future<void> _send(Map<String, Object?> state) async {
    if (_closed) return;
    final content = jsonEncode([
      state,
      for (final entry in _displayed.entries)
        [entry.key, entry.value.reviewToken],
    ]);
    if (content == _publishedContent) return;
    _publishedContent = content;
    final presentation = ++_presentation;
    try {
      await publish({
        ...state,
        'presentation': presentation,
      }).timeout(const Duration(seconds: 2));
    } on Object {
      if (_presentation == presentation) _publishedContent = null;
      // Native menu availability does not own the workspace lifetime.
    }
  }

  Map<String, Object?> _payload(
    String location, {
    int? approvals,
    int? proposals,
    List<Map<String, Object?>> requests = const [],
    List<Map<String, Object?>> submissions = const [],
  }) {
    final palette = UiPalette.zhiyu(
      theme() == WorkspaceTheme.dark ? Brightness.dark : Brightness.light,
    );
    return {
      'binding': _binding,
      'location': location,
      'dark': theme() == WorkspaceTheme.dark,
      'ready': approvals != null && proposals != null,
      'approvalCount': approvals,
      'proposalCount': proposals,
      'requests': requests,
      'proposals': submissions,
      'notice': approvals != null || _uncertain != null ? _notice : null,
      'checkResult': _uncertain != null && !_busy,
      'colors': {
        'accent': palette.accent.toARGB32(),
        'ink': palette.ink.toARGB32(),
        'muted': palette.muted.toARGB32(),
        'paper': palette.paper.toARGB32(),
        'rail': palette.rail.toARGB32(),
        'line': palette.line.toARGB32(),
        'onAccent': palette.onAccent.toARGB32(),
      },
    };
  }

  bool _current(WorkspaceSource source, int binding) =>
      !_closed &&
      !_offline &&
      binding == _binding &&
      identical(source, _source);

  Future<void> refresh() {
    _again = true;
    return _reading ??= _readUntilCurrent().whenComplete(() {
      _reading = null;
      if (_again && !_closed) unawaited(refresh());
    });
  }

  Future<void> _readUntilCurrent() async {
    while (_again && !_closed) {
      _again = false;
      final source = _source;
      final binding = _binding;
      final connection = _connectionRevision;
      if (source == null || _offline) return;
      try {
        final approvals = await source.approvals.query(
          const WorkspaceApprovalQuery(limit: 3),
        );
        final proposals = await source.proposals.query(
          const WorkspaceProposalQuery(
            filter: WorkspaceProposalFilter.pending,
            limit: 3,
          ),
        );
        final details = await Future.wait([
          for (final row in approvals.items) source.approvals.read(row.id),
        ]);
        if (!_current(source, binding) || connection != _connectionRevision) {
          continue;
        }
        // A row can expire or be handled between the queue and detail reads.
        if (details.any(
          (detail) => detail.request.state != WorkspaceApprovalState.pending,
        )) {
          _displayed.clear();
          await _send(_payload('正在更新待办…'));
          if (_current(source, binding)) {
            _expiry?.cancel();
            _expiry = Timer(
              const Duration(seconds: 1),
              () => unawaited(refresh()),
            );
          }
          continue;
        }
        _displayed
          ..clear()
          ..addEntries(details.map((d) => MapEntry(d.request.id, d)));
        _expiry?.cancel();
        if (details.isNotEmpty) {
          final next = details
              .map((d) => d.request.requestExpiresAt)
              .reduce((a, b) => a.isBefore(b) ? a : b);
          final wait = next.difference(_clock());
          if (wait > Duration.zero) {
            _expiry = Timer(wait, () => unawaited(refresh()));
          }
        }
        await _send(
          _payload(
            _location,
            approvals: approvals.pending,
            proposals: proposals.pending,
            requests: details.map(_approval).toList(),
            submissions: [
              for (final row in proposals.items)
                {
                  'id': row.id,
                  'title': row.title,
                  'agent': row.agentClaim,
                  'purpose': row.purpose,
                  'scope':
                      '${row.kind.label} · ${row.itemCount} 项 · ${row.status.label}',
                },
            ],
          ),
        );
      } on Object {
        if (!_current(source, binding) || connection != _connectionRevision) {
          continue;
        }
        _displayed.clear();
        await _send(_payload('无法读取待办，打开菜单重试'));
      }
    }
  }

  List<WorkspaceApprovalScope> _fields(WorkspaceApprovalDetail d) =>
      d.scopes.where((s) => s.requested).toList();

  bool _quick(WorkspaceApprovalDetail d) {
    final fields = _fields(d);
    return d.request.kind == WorkspaceApprovalKind.information &&
        d.request.agentClaim.trim().isNotEmpty &&
        d.request.purpose.trim().isNotEmpty &&
        d.credential == null &&
        d.canApprove &&
        fields.isNotEmpty &&
        fields.every(
          (s) =>
              s.kind == WorkspaceApprovalScopeKind.field &&
              s.available &&
              s.recordName.trim().isNotEmpty &&
              s.label.trim().isNotEmpty,
        );
  }

  Map<String, Object?> _approval(WorkspaceApprovalDetail d) => {
    'id': d.request.id,
    'title': d.request.title,
    'agent': d.request.agentClaim,
    'purpose': d.request.purpose,
    'scope': _fields(d).map((s) => '${s.recordName} · ${s.label}').join('\n'),
    'quick': _quick(d) && _uncertain == null && !_busy,
    'duration': '授权时长 · ${AccessTiming.defaultMinutes ~/ 60} 小时',
  };

  Future<void> handle(String method, Object? raw) async {
    if (_closed) return;
    if (method == 'pendingMenuRefresh') {
      if (!_busy && _uncertain == null) _notice = null;
      return refresh();
    }
    final source = _source;
    if (raw is! Map ||
        source == null ||
        raw['presentation'] != _presentation ||
        _offline ||
        !canAct() ||
        _busy) {
      return;
    }
    final id = raw['id'];
    if (id != null && id is! String) return;
    if (method == 'pendingMenuOpen') {
      final page = switch (raw['category']) {
        'approvals' => WorkspacePage.approvals,
        'proposals' => WorkspacePage.proposals,
        _ => null,
      };
      if (page != null) await open(page, id as String?);
    } else if (method == 'pendingMenuDecision' &&
        id is String &&
        raw['approve'] is bool &&
        _uncertain == null) {
      final shown = _displayed[id];
      if (shown == null || !_quick(shown)) return;
      await (_action = _decide(
        source,
        _binding,
        shown,
        raw['approve'] as bool,
      ));
    } else if (method == 'pendingMenuCheck' && _uncertain != null) {
      await (_action = _check(source, _binding));
    }
  }

  Future<void> _decide(
    WorkspaceSource source,
    int binding,
    WorkspaceApprovalDetail shown,
    bool approve,
  ) async {
    _busy = true;
    _notice = null;
    try {
      final current = await source.approvals.read(shown.request.id);
      if (!_current(source, binding) || !canAct()) return;
      if (current.reviewToken != shown.reviewToken ||
          !_quick(current) ||
          current.request.state != WorkspaceApprovalState.pending) {
        _notice = '申请已变化，请重新核对。';
        return;
      }
      final change = WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        requestId: current.request.id,
        reviewToken: shown.reviewToken,
        action: approve
            ? WorkspaceApprovalAction.approve
            : WorkspaceApprovalAction.deny,
        selected: approve ? _fields(shown).map((s) => s.id) : const [],
      );
      _uncertain = change;
      try {
        _confirm(change, await source.approvals.change(change));
        if (_current(source, binding)) {
          _uncertain = null;
          _notice = '已记录本次决定。';
        }
      } on WorkspaceFailure catch (failure) {
        if (!_current(source, binding)) return;
        if (failure.code == 'unknown_outcome') {
          _notice = '结果尚未确认，请核对。';
        } else {
          _uncertain = null;
          _notice = failure.message;
        }
      } on Object {
        if (_current(source, binding)) _notice = '结果尚未确认，请核对。';
      }
    } on Object {
      if (_current(source, binding)) _notice = '暂时无法核对申请，请重试。';
    } finally {
      if (binding == _binding) {
        _busy = false;
        await refresh();
      }
    }
  }

  Future<void> _check(WorkspaceSource source, int binding) async {
    _busy = true;
    final change = _uncertain!;
    try {
      final receipt = await source.approvals.receipt(change.operationId);
      if (!_current(source, binding)) return;
      if (receipt != null) _confirm(change, receipt);
      _notice = receipt == null ? '原操作未提交。请重新核对申请。' : '已记录本次决定。';
      _uncertain = null;
    } on Object {
      if (_current(source, binding)) _notice = '结果尚未确认，请核对。';
    } finally {
      if (binding == _binding) {
        _busy = false;
        await refresh();
      }
    }
  }

  void _confirm(
    WorkspaceApprovalChange change,
    WorkspaceApprovalReceipt receipt,
  ) {
    if (!receipt.matches(change)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次决定不符，请继续核对。');
    }
  }

  void dispose() {
    _closed = true;
    _expiry?.cancel();
    _displayed.clear();
  }
}
