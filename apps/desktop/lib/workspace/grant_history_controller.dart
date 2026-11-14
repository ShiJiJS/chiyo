import 'dart:async';
import 'workspace_refresh.dart';
import 'package:flutter/foundation.dart';
import 'approvals_controller.dart';
import 'workspace_source.dart';

/// Owns history queries/reading positions. Decisions still use the same approval
/// command/receipt controller and source, with an independent inbox projection.
class GrantHistoryController extends ChangeNotifier {
  GrantHistoryController(
    this.source,
    WorkspaceApprovalSource approvals,
    this.changes,
  ) : decision = ApprovalsController(approvals, const Stream.empty()) {
    decision.addListener(_notify);
    _subscription = changes.listen((_) {
      if (!frozen) {
        unawaited(load(background: true));
      }
    });
  }
  final WorkspaceGrantHistorySource source;
  final Stream<WorkspaceRecordRef?> changes;
  final ApprovalsController decision;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspaceGrantResults? results;
  WorkspaceGrantDetail? detail;
  WorkspaceFailure? readFailure;
  WorkspaceGrantFilter filter = WorkspaceGrantFilter.all;
  WorkspaceApprovalKind? kind;
  String keyword = '';
  int? lastDays;
  int offset = 0, limit = 20, _generation = 0;
  String? selection, notice;
  String? _explicitTarget;
  double listScroll = 0, detailScroll = 0;
  bool loading = false, reading = false, _revoking = false, _closed = false;
  bool get frozen => _revoking || decision.frozen;
  bool get linkedDecision =>
      detail?.summary.requestId != null &&
      detail!.summary.requestId == decision.detail?.request.id;
  bool get canRevoke =>
      !frozen &&
      !loading &&
      !reading &&
      readFailure == null &&
      detail?.canRevoke == true &&
      linkedDecision &&
      decision.canDecide &&
      decision.detail!.reviewToken == detail!.reviewToken;
  WorkspaceFailure? get decisionFailure =>
      linkedDecision ? decision.writeFailure ?? decision.readFailure : null;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  WorkspaceGrantQuery _query({int? at}) => WorkspaceGrantQuery(
    keyword: keyword,
    filter: filter,
    kind: kind,
    lastDays: lastDays,
    offset: at ?? offset,
    limit: limit,
  );

  final _refresh = WorkspaceRefresh();
  Future<void> load({bool review = false, bool background = false}) =>
      _refresh.run(() => _load(review: review), background: background);

  Future<void> _load({required bool review}) async {
    if (_closed) return;
    if (frozen) return;
    final generation = ++_generation;
    loading = true;
    readFailure = null;
    _notify();
    try {
      var found = await source.query(_query(), keepSelection: selection);
      if (_closed || generation != _generation) return;
      if (filter == WorkspaceGrantFilter.active &&
          selection != null &&
          found.selection != selection &&
          detail != null) {
        WorkspaceGrantDetail? prior;
        try {
          prior = await source.read(selection!);
        } on WorkspaceFailure catch (e) {
          if (e.code != 'not_found') rethrow;
        }
        if (_closed || generation != _generation) return;
        if (prior != null && !prior.summary.state.isActive) {
          filter = WorkspaceGrantFilter.all;
          notice = '所选授权已结束，正在显示它的当前状态。';
          found = await source.query(_query(), keepSelection: selection);
          if (_closed || generation != _generation) return;
        }
      }
      if (_explicitTarget != null && found.selection != _explicitTarget) {
        results = found;
        selection = _explicitTarget;
        detail = null;
        readFailure = const WorkspaceFailure(
          'not_found',
          '指定历史已不存在或已清理，请选择列表中的记录。',
        );
        return;
      }
      if (found.selectionIndex case final index?
          when index < found.offset || index >= found.offset + limit) {
        found = await source.query(
          _query(at: index ~/ limit * limit),
          keepSelection: found.selection,
        );
        if (_closed || generation != _generation) return;
      }
      if (selection != found.selection) {
        detail = null;
        detailScroll = 0;
      }
      results = found;
      offset = found.offset;
      selection = found.selection;
      if (selection == null) {
        detail = null;
        return;
      }
      reading = true;
      _notify();
      final current = await source.read(selection!);
      if (_closed || generation != _generation) return;
      detail = current;
      if (current.summary.requestId case final request?) {
        final expanded = decision.selection == request
            ? {...?decision.draft?.expanded}
            : <String>{};
        await decision.open(request);
        decision.draft?.expanded.addAll(expanded);
        if (_closed || generation != _generation) return;
        if (review && decision.readFailure == null) {
          await decision.reviewCurrent();
        }
      }
    } catch (error) {
      if (!_closed && generation == _generation) {
        readFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法读取授权历史，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = reading = false;
        _notify();
      }
    }
  }

  Future<void> open(String id) async {
    if (frozen || _closed) return;
    keyword = '';
    filter = WorkspaceGrantFilter.all;
    kind = null;
    lastDays = null;
    offset = 0;
    _explicitTarget = id;
    selection = id;
    detail = null;
    notice = null;
    detailScroll = 0;
    await load();
  }

  Future<void> select(String id) async {
    if (frozen || _closed) return;
    _explicitTarget = id;
    selection = id;
    detail = null;
    detailScroll = 0;
    notice = null;
    await load();
  }

  Future<void> search(String text) async {
    if (frozen || _closed) return;
    keyword = text;
    _explicitTarget = null;
    selection = null;
    offset = 0;
    listScroll = 0;
    notice = null;
    await load();
  }

  Future<void> setFilter(WorkspaceGrantFilter value) =>
      setFilters(filter: value, kind: kind, lastDays: lastDays);

  Future<void> setKind(WorkspaceApprovalKind? value) =>
      setFilters(filter: filter, kind: value, lastDays: lastDays);

  Future<void> setDays(int? value) =>
      setFilters(filter: filter, kind: kind, lastDays: value);

  Future<void> setFilters({
    required WorkspaceGrantFilter filter,
    required WorkspaceApprovalKind? kind,
    required int? lastDays,
  }) async {
    if (frozen || _closed) return;
    this.filter = filter;
    this.kind = kind;
    this.lastDays = lastDays;
    _explicitTarget = null;
    selection = null;
    offset = 0;
    listScroll = 0;
    notice = null;
    await load();
  }

  Future<void> page(int value) async {
    if (frozen || _closed) return;
    offset = value;
    _explicitTarget = null;
    selection = null;
    listScroll = 0;
    await load();
  }

  Future<void> revoke() async {
    if (!canRevoke) return;
    _revoking = true;
    notice = null;
    _notify();
    try {
      await decision.decide(WorkspaceApprovalAction.revoke);
    } finally {
      _revoking = false;
      _notify();
    }
    if (_closed || decision.uncertain || decision.writeFailure != null) return;
    detailScroll = 0;
    await load();
  }

  Future<void> reconcile() async {
    if (_closed || !decision.uncertain) return;
    await decision.reconcile();
    if (_closed || decision.uncertain) return;
    await load();
  }

  void resetView() {
    if (frozen || _closed) return;
    _explicitTarget = null;
    selection = null;
    detail = null;
    readFailure = null;
    notice = null;
    keyword = '';
    filter = WorkspaceGrantFilter.all;
    kind = null;
    lastDays = null;
    offset = 0;
    listScroll = detailScroll = 0;
    decision.resetView();
    unawaited(load());
  }

  @override
  void dispose() {
    _refresh.dispose();
    _closed = true;
    _generation++;
    decision.removeListener(_notify);
    decision.dispose();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
