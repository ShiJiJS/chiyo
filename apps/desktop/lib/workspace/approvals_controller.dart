import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class ApprovalDraft {
  ApprovalDraft(WorkspaceApprovalDetail detail)
    : reviewToken = detail.reviewToken,
      selected = {
        ...detail.request.state == WorkspaceApprovalState.pending
            ? detail.scopes.where((x) => x.requested).map((x) => x.id)
            : detail.approved,
      },
      files = {...detail.fileVersions} {
    for (final x in detail.scopes.where(
      (x) => x.kind == WorkspaceApprovalScopeKind.file,
    )) {
      final versions = x.fileVersions.map((v) => v.ref.version).toList()
        ..sort();
      if (!files.containsKey(x.id) && versions.isNotEmpty) {
        files[x.id] = versions.last;
      }
    }
  }
  String reviewToken;
  final Set<String> selected;
  final Map<String, int> files;
  final Set<String> expanded = {};
  int fieldMinutes = 30, credentialMinutes = 15;
  bool dirty = false;
}

/// Root-owned projections/drafts; the source alone owns request/decision facts.
class ApprovalsController extends ChangeNotifier {
  ApprovalsController(this.source, Stream<WorkspaceRecordRef?> changes) {
    _subscription = changes.listen((_) {
      if (frozen) {
        _refreshPending = true;
      } else {
        unawaited(load());
      }
    });
  }
  final WorkspaceApprovalSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspaceApprovalResults? results;
  WorkspaceApprovalDetail? detail;
  WorkspaceFailure? readFailure, writeFailure;
  String keyword = '';
  WorkspaceApprovalFilter filter = WorkspaceApprovalFilter.pending;
  int offset = 0, limit = 20, _generation = 0;
  String? selection, notice;
  String? _explicitTarget;
  bool loading = false,
      reading = false,
      busy = false,
      _closed = false,
      _refreshPending = false;
  double listScroll = 0, detailScroll = 0;
  final _drafts = <String, ApprovalDraft>{};
  final _executionReads = <(String, String), ({int serial, int generation})>{};
  int _executionSerial = 0;
  final _executionErrors = <(String, String), String>{};
  bool readingExecution(String id) =>
      _executionReads[(selection, id)]?.generation == _generation;
  String? executionError(String id) => _executionErrors[(selection, id)];

  Future<void> refreshExecution(String id) async {
    if (_closed ||
        frozen ||
        loading ||
        reading ||
        readingExecution(id) ||
        detail == null) {
      return;
    }
    final old = detail!.executions
        .where((e) => e.operationId == id)
        .firstOrNull;
    if (old == null) return;
    final request = selection!, generation = _generation, key = (request, id);
    final serial = ++_executionSerial;
    _executionReads[key] = (serial: serial, generation: generation);
    _executionErrors.remove(key);
    _notify();
    try {
      final next = await source.execution(request, id);
      if (_closed ||
          generation != _generation ||
          selection != request ||
          frozen) {
        return;
      }
      if (!next.updates(old)) {
        throw const WorkspaceFailure(
          'unknown_outcome',
          '使用结果与原操作不符，原状态已保留。请继续查询原操作，不要重跑。',
        );
      }
      detail = detail!.withExecution(next);
    } catch (error) {
      if (!_closed && generation == _generation && selection == request) {
        _executionErrors[key] = error is WorkspaceFailure
            ? error.message
            : '暂时无法确认原操作，原状态已保留。请稍后查询，不要重跑。';
      }
    } finally {
      if (_executionReads[key]?.serial == serial) _executionReads.remove(key);
      _notify();
    }
  }

  WorkspaceApprovalChange? _command;
  bool get uncertain => writeFailure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  ApprovalDraft? get draft => selection == null ? null : _drafts[selection];
  bool get needsReview =>
      detail != null && draft?.reviewToken != detail!.reviewToken;
  bool get canDecide =>
      !frozen &&
      !loading &&
      !reading &&
      readFailure == null &&
      detail != null &&
      detail!.decisionUnavailableReason == null &&
      !needsReview &&
      writeFailure?.code != 'conflict';
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> load({bool accepted = false}) async {
    if (_closed || frozen) {
      _refreshPending = true;
      return;
    }
    final generation = ++_generation;
    loading = true;
    readFailure = null;
    _notify();
    try {
      var found = await source.query(
        WorkspaceApprovalQuery(
          keyword: keyword,
          filter: filter,
          offset: offset,
          limit: limit,
        ),
        keepSelection: selection,
      );
      if (_closed || generation != _generation) return;
      if (_explicitTarget != null && found.selection != _explicitTarget) {
        // A notification/deep link must never silently select an unrelated
        // request. Keep the missing target through automatic refresh/retry.
        results = found;
        selection = _explicitTarget;
        detail = null;
        readFailure = const WorkspaceFailure(
          'not_found',
          '未找到指定申请，可能已清理或属于其他资料库。请选择列表中的申请。',
        );
        return;
      }
      if (filter == WorkspaceApprovalFilter.pending &&
          selection != null &&
          found.selection != selection &&
          detail != null) {
        WorkspaceApprovalDetail? prior;
        try {
          prior = await source.read(selection!);
        } on WorkspaceFailure catch (e) {
          if (e.code != 'not_found') rethrow;
          notice = '原请求已不存在，正在显示当前收件箱。';
        }
        if (_closed || generation != _generation) return;
        if (prior != null &&
            prior.request.state != WorkspaceApprovalState.pending) {
          filter = WorkspaceApprovalFilter.all;
          notice = '原请求已处理或结束，正在显示它的当前状态。';
          found = await source.query(
            WorkspaceApprovalQuery(
              keyword: keyword,
              filter: filter,
              offset: offset,
              limit: limit,
            ),
            keepSelection: selection,
          );
          if (_closed || generation != _generation) return;
        }
      }
      if (found.selectionIndex case final index?
          when index < found.offset || index >= found.offset + limit) {
        found = await source.query(
          WorkspaceApprovalQuery(
            keyword: keyword,
            filter: filter,
            offset: index ~/ limit * limit,
            limit: limit,
          ),
          keepSelection: found.selection,
        );
        if (_closed || generation != _generation) return;
      }
      if (selection != found.selection) {
        notice = null;
        writeFailure = null;
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
      if (accepted ||
          _drafts[selection] == null ||
          current.request.state != WorkspaceApprovalState.pending) {
        _drafts[selection!] = ApprovalDraft(current);
      }
    } catch (e) {
      if (!_closed && generation == _generation) {
        readFailure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unavailable', '暂时无法读取审批，请重试。');
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
    _explicitTarget = id;
    if (selection != id) {
      detail = null;
      detailScroll = 0;
      readFailure = writeFailure = null;
      notice = null;
    }
    filter = WorkspaceApprovalFilter.all;
    keyword = '';
    offset = 0;
    selection = id;
    await load();
  }

  Future<void> select(String id) async {
    if (frozen || _closed) return;
    _explicitTarget = null;
    selection = id;
    detail = null;
    detailScroll = 0;
    readFailure = null;
    writeFailure = null;
    notice = null;
    final generation = ++_generation;
    loading = false;
    reading = true;
    _notify();
    try {
      final current = await source.read(id);
      if (_closed || generation != _generation) return;
      detail = current;
      if (current.request.state != WorkspaceApprovalState.pending) {
        _drafts[id] = ApprovalDraft(current);
      } else {
        _drafts.putIfAbsent(id, () => ApprovalDraft(current));
      }
    } catch (e) {
      if (!_closed && generation == _generation) {
        readFailure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unavailable', '请求暂时无法读取。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        reading = false;
        _notify();
      }
    }
  }

  Future<void> search(String text) async {
    if (frozen) return;
    _explicitTarget = null;
    keyword = text;
    notice = null;
    offset = 0;
    selection = null;
    listScroll = 0;
    await load();
  }

  Future<void> setFilter(WorkspaceApprovalFilter value) async {
    if (frozen) return;
    _explicitTarget = null;
    filter = value;
    notice = null;
    offset = 0;
    selection = null;
    listScroll = 0;
    await load();
  }

  Future<void> page(int value) async {
    if (frozen) return;
    _explicitTarget = null;
    offset = value;
    notice = null;
    selection = null;
    listScroll = 0;
    await load();
  }

  void edited() {
    if (frozen) return;
    draft?.dirty = true;
    if (writeFailure?.code != 'conflict') writeFailure = null;
    notice = null;
    _notify();
  }

  void toggle(String id) {
    if (!canDecide || detail!.request.state != WorkspaceApprovalState.pending) {
      return;
    }
    draft!.selected.contains(id)
        ? draft!.selected.remove(id)
        : draft!.selected.add(id);
    edited();
  }

  void expand(String section) {
    if (frozen) return;
    draft!.expanded.contains(section)
        ? draft!.expanded.remove(section)
        : draft!.expanded.add(section);
    _notify();
  }

  void chooseFile(String id, int version) {
    if (!canDecide) return;
    draft!.files[id] = version;
    edited();
  }

  void lifetime(int value, {bool credential = false}) {
    if (!canDecide) return;
    if (credential) {
      draft!.credentialMinutes = value;
    } else {
      draft!.fieldMinutes = value;
    }
    edited();
  }

  Future<void> reviewCurrent() async {
    if (frozen || selection == null) return;
    final id = selection!, generation = _generation + 1;
    await select(id);
    if (selection != id ||
        _generation != generation ||
        detail == null ||
        readFailure != null) {
      return;
    }
    final d = draft!;
    if (detail!.request.state != WorkspaceApprovalState.pending) {
      _drafts[selection!] = ApprovalDraft(detail!);
    } else {
      d.reviewToken = detail!.reviewToken;
      d.dirty = true;
    }
    writeFailure = null;
    notice = '已重新读取当前范围，原勾选仍保留；请核对不可用项和版本后再决定。';
    _notify();
  }

  WorkspaceApprovalReceipt _check(WorkspaceApprovalReceipt r) {
    final c = _command!;
    if (r.operationId != c.operationId ||
        r.requestId != c.requestId ||
        r.action != c.action ||
        r.reviewToken != c.reviewToken ||
        r.commandDigest != c.digest ||
        r.revision < 1) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次决定不符，请继续核对。');
    }
    return r;
  }

  Future<void> _finished(WorkspaceApprovalReceipt receipt) async {
    busy = false;
    _command = null;
    writeFailure = null;
    _refreshPending = false;
    _drafts.remove(receipt.requestId);
    selection = receipt.requestId;
    filter = WorkspaceApprovalFilter.all;
    notice = '本次决定已记录。';
    _notify();
    await load(accepted: true);
  }

  Future<void> decide(WorkspaceApprovalAction action) async {
    if (!canDecide) return;
    final d = draft!, current = detail!;
    d.dirty = true;
    _command = WorkspaceApprovalChange(
      operationId: workspaceOperationId(),
      requestId: current.request.id,
      reviewToken: d.reviewToken,
      action: action,
      selected: action == WorkspaceApprovalAction.approve
          ? d.selected
          : const [],
      fileVersions: action == WorkspaceApprovalAction.approve
          ? {
              for (final x in current.scopes)
                if (x.kind == WorkspaceApprovalScopeKind.file &&
                    d.selected.contains(x.id) &&
                    d.files[x.id] != null)
                  x.id: d.files[x.id]!,
            }
          : const {},
      fieldMinutes: d.fieldMinutes,
      credentialMinutes: d.credentialMinutes,
    );
    busy = true;
    writeFailure = null;
    notice = null;
    _notify();
    try {
      final r = _check(await source.change(_command!));
      if (!_closed) await _finished(r);
    } catch (e) {
      if (!_closed) {
        busy = false;
        writeFailure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unknown_outcome', '审批结果未知，请先核对结果。');
        if (!uncertain) _command = null;
        _notify();
        if (!uncertain && _refreshPending) {
          _refreshPending = false;
          await load();
        }
      }
    }
  }

  Future<void> reconcile() async {
    if (!uncertain || busy || _command == null || _closed) return;
    busy = true;
    _notify();
    try {
      final r = await source.receipt(_command!.operationId);
      if (r != null) {
        final checked = _check(r);
        if (!_closed) await _finished(checked);
      } else if (!_closed) {
        busy = false;
        _command = null;
        writeFailure = null;
        notice = '已确认本次尚未提交，原选择已保留；请核对当前范围后再决定。';
        _notify();
        _refreshPending = false;
        await load();
      }
    } catch (_) {
      if (!_closed) {
        busy = false;
        writeFailure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认本次决定，请稍后核对。',
        );
        _notify();
      }
    }
  }

  void resetView() {
    if (frozen) return;
    _drafts.clear();
    _executionErrors.clear();
    _executionReads.clear();
    readFailure = writeFailure = null;
    notice = null;
    _command = null;
    selection = null;
    detail = null;
    keyword = '';
    offset = 0;
    filter = WorkspaceApprovalFilter.pending;
    listScroll = detailScroll = 0;
    unawaited(load());
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
