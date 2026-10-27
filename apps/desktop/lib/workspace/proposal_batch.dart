import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

enum ProposalBatchStatus {
  notStarted('未开始'),
  processing('处理中'),
  completed('已提交'),
  rejected('已拒绝'),
  conflict('版本冲突'),
  failed('确定未提交'),
  unknown('结果未知'),
  notSubmitted('已核对未提交'),
  obsolete('已由其他决定处理');

  const ProposalBatchStatus(this.label);
  final String label;
}

class ProposalBatchEntry {
  ProposalBatchEntry(WorkspaceProposalDetail d, WorkspaceProposalChange c)
    : summary = d.summary,
      command = c,
      expectation = WorkspaceProposalExpectation(d),
      fingerprint = d.snapshotDigest,
      action = c.action,
      names = List.unmodifiable(c.reviewed.map((x) => x.name));
  final WorkspaceProposalSummary summary;
  final WorkspaceProposalAction action;
  final List<String> names;
  final WorkspaceProposalExpectation expectation;
  final String fingerprint;
  WorkspaceProposalChange? command;
  ProposalBatchStatus status = ProposalBatchStatus.notStarted;
  WorkspaceFailure? failure;
  WorkspaceProposalReceipt? receipt;
  bool get terminal =>
      status == ProposalBatchStatus.completed ||
      status == ProposalBatchStatus.rejected ||
      status == ProposalBatchStatus.obsolete;
}

/// Sequential independent decisions. It has no transaction or rollback across
/// proposals and never holds derived Owner-before bodies in its review plan.
class ProposalBatch extends ChangeNotifier {
  ProposalBatch(this.source, {required this.onHandled});
  final WorkspaceProposalSource source;
  final void Function(String) onHandled;
  final _entries = <ProposalBatchEntry>[];
  List<ProposalBatchEntry> get entries => List.unmodifiable(_entries);
  ProposalBatchEntry? entry(String id) =>
      _entries.where((e) => e.summary.id == id).firstOrNull;
  bool busy = false, started = false, _closed = false;
  bool _refreshing = false, _refreshAgain = false;
  int _revision = 0;
  bool get uncertain =>
      _entries.any((e) => e.status == ProposalBatchStatus.unknown);
  bool get frozen => busy || uncertain;
  int get pendingCount =>
      _entries.where((e) => e.status == ProposalBatchStatus.notStarted).length;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  bool stage(WorkspaceProposalDetail d, WorkspaceProposalChange c) {
    if (_closed ||
        frozen ||
        !d.summary.pending ||
        d.summary.id != c.proposalId ||
        d.summary.version != c.version ||
        d.reviewToken != c.reviewToken ||
        c.action == WorkspaceProposalAction.confirm && !d.canConfirm) {
      return false;
    }
    if (c.action == WorkspaceProposalAction.confirm &&
            (c.reviewed.isEmpty ||
                c.reviewed.map((i) => i.itemId).toSet().length !=
                    c.reviewed.length ||
                c.reviewed.any(
                  (i) => !d.items.any((original) => original.id == i.itemId),
                )) ||
        c.action == WorkspaceProposalAction.reject && c.reviewed.isNotEmpty) {
      return false;
    }
    final old = entry(c.proposalId);
    if (old?.terminal == true || _entries.length >= 100 && old == null) {
      return false;
    }
    final next = ProposalBatchEntry(d, c);
    _revision++;
    if (old != null) {
      old.command = null;
      _entries[_entries.indexOf(old)] = next;
    } else {
      _entries.add(next);
    }
    _notify();
    return true;
  }

  void remove(String id) {
    if (_closed || frozen) return;
    _revision++;
    entry(id)?.command = null;
    _entries.removeWhere((e) => e.summary.id == id);
    _notify();
  }

  void move(String id, int delta) {
    if (_closed || frozen || started) return;
    final index = _entries.indexWhere((e) => e.summary.id == id),
        next = index + delta;
    if (index < 0 || next < 0 || next >= _entries.length) return;
    _entries.insert(next, _entries.removeAt(index));
    _notify();
  }

  void clear() {
    if (_closed || frozen) return;
    _revision++;
    for (final e in _entries) {
      e.command = null;
    }
    _entries.clear();
    started = false;
    _notify();
  }

  void observeHandled(WorkspaceProposalDetail d) {
    if (!d.summary.pending) handledElsewhere(d.summary.id);
  }

  void handledElsewhere(String id) {
    final e = entry(id);
    if (_closed || frozen || e == null || e.terminal) return;
    e.command = null;
    e.status = ProposalBatchStatus.obsolete;
    e.failure = null;
    _notify();
  }

  /// Retire hidden terminal rows using queue metadata only. This never reads
  /// Owner-before bodies or treats another decision as this batch's receipt.
  Future<void> refreshMetadata() async {
    if (_closed || frozen) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        final revision = _revision;
        for (final e in List<ProposalBatchEntry>.of(_entries)) {
          if (_closed || frozen || revision != _revision) break;
          if (e.terminal || e.command == null) continue;
          try {
            final result = await source.query(
              const WorkspaceProposalQuery(limit: 1),
              keepSelection: e.summary.id,
            );
            var missing = result.selection != e.summary.id;
            WorkspaceProposalSummary? summary;
            if (!missing) {
              final index = result.selectionIndex;
              if (index == null) continue;
              final page = index == result.offset
                  ? result
                  : await source.query(
                      WorkspaceProposalQuery(offset: index, limit: 1),
                      keepSelection: e.summary.id,
                    );
              // A moved page is ambiguous, not evidence of disappearance.
              summary = page.items
                  .where((row) => row.id == e.summary.id)
                  .firstOrNull;
              missing = page.selection != e.summary.id;
            }
            if (_closed || frozen || revision != _revision) break;
            if (missing || summary?.pending == false) {
              handledElsewhere(e.summary.id);
              onHandled(e.summary.id);
            }
          } catch (_) {
            // Keep explicit review on read failure; preflight remains required.
          }
        }
      } while (_refreshAgain && !_closed && !frozen);
    } finally {
      _refreshing = false;
    }
  }

  // Return before the write await, releasing any transient Owner-before detail.
  Future<bool> _preflight(ProposalBatchEntry e) async {
    final c = e.command!, d = await source.read(c.proposalId);
    if (_closed) return false;
    if (!d.summary.pending) {
      e.command = null;
      e.status = ProposalBatchStatus.obsolete;
      e.failure = const WorkspaceFailure(
        'already_handled',
        '本批次没有重复提交这份已处理提案。',
      );
      onHandled(e.summary.id);
      return false;
    }
    if (d.summary.version != c.version ||
        d.reviewToken != c.reviewToken ||
        d.snapshotDigest != e.fingerprint ||
        c.action == WorkspaceProposalAction.confirm && !d.canConfirm) {
      throw const WorkspaceFailure(
        'conflict',
        '提案、资料或分类已变化，原审阅保留；请单独核对，不能自动换基。',
      );
    }
    return true;
  }

  void _finish(ProposalBatchEntry e, WorkspaceProposalReceipt receipt) {
    e.receipt = receipt;
    e.command = null;
    e.failure = null;
    e.status = e.action == WorkspaceProposalAction.confirm
        ? ProposalBatchStatus.completed
        : ProposalBatchStatus.rejected;
    onHandled(e.summary.id);
  }

  Future<void> _execute(ProposalBatchEntry e) async {
    e.status = ProposalBatchStatus.processing;
    e.failure = null;
    _notify();
    var submitted = false;
    try {
      if (!await _preflight(e) || _closed) return;
      final c = e.command!;
      submitted = true;
      final r = await source.change(c);
      if (!_closed) _finish(e, e.expectation.check(c, r));
    } catch (error) {
      if (_closed) return;
      final failure = error is WorkspaceFailure
          ? error
          : WorkspaceFailure(
              submitted ? 'unknown_outcome' : 'unavailable',
              submitted ? '结果暂时无法确认，请核对原操作。' : '尚未提交，暂时无法核对提案。',
            );
      e.failure = failure;
      e.status = failure.code == 'unknown_outcome'
          ? ProposalBatchStatus.unknown
          : failure.code == 'conflict'
          ? ProposalBatchStatus.conflict
          : ProposalBatchStatus.failed;
    } finally {
      _notify();
    }
  }

  Future<void> runPending() async {
    if (_closed || frozen || pendingCount == 0) return;
    _revision++;
    busy = started = true;
    _notify();
    try {
      for (final e in List<ProposalBatchEntry>.of(_entries)) {
        if (_closed || uncertain) break;
        if (e.status == ProposalBatchStatus.notStarted) await _execute(e);
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> reconcile() async {
    if (_closed || busy || !uncertain) return;
    final e = _entries.firstWhere(
          (e) => e.status == ProposalBatchStatus.unknown,
        ),
        c = e.command!;
    busy = true;
    _notify();
    try {
      final r = await source.receipt(c.operationId);
      if (_closed) return;
      if (r == null) {
        e.status = ProposalBatchStatus.notSubmitted;
        e.failure = null;
      } else {
        _finish(e, e.expectation.check(c, r));
      }
    } catch (_) {
      if (!_closed) {
        e.failure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认原操作，请继续核对；未开始项保持原样。',
        );
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> retry(String id) async {
    final e = entry(id);
    if (_closed ||
        frozen ||
        e == null ||
        ![
          ProposalBatchStatus.failed,
          ProposalBatchStatus.notSubmitted,
        ].contains(e.status)) {
      return;
    }
    final c = e.command!;
    _revision++;
    e.command = WorkspaceProposalChange(
      operationId: workspaceOperationId(),
      proposalId: c.proposalId,
      version: c.version,
      reviewToken: c.reviewToken,
      action: c.action,
      reviewed: c.reviewed,
    );
    busy = true;
    _notify();
    try {
      await _execute(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _revision++;
    for (final e in _entries) {
      e.command = null;
    }
    _entries.clear();
    super.dispose();
  }
}
