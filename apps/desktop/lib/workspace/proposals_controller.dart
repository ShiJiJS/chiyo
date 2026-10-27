import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class ProposalDraft {
  ProposalDraft(WorkspaceProposalDetail d)
    : version = d.summary.version,
      sourceFingerprint = d.snapshotDigest,
      originals = Map<String, WorkspaceProposalItem>.unmodifiable({
        for (final i in d.items) i.id: i.withoutOwnerBefore(),
      }),
      reviewToken = d.reviewToken,
      selected = {for (final i in d.items) i.id},
      items = {
        for (final i in d.items) i.id: WorkspaceProposalItemReview.fromItem(i),
      };
  final int version;
  final String sourceFingerprint;
  final Map<String, WorkspaceProposalItem> originals;
  String reviewToken;
  final Set<String> selected;
  final Map<String, WorkspaceProposalItemReview> items;
  bool dirty = false;
}

/// Owns transient Owner review, not a second set of proposal/record facts.
/// Navigation keeps the controller alive; terminal source rows clear bodies.
class ProposalsController extends ChangeNotifier {
  ProposalsController(this.source, this.changes) {
    _subscription = changes.listen((ref) {
      if (_closed) return;
      _invalidateOwnerBefore(ref);
      if (frozen) return;
      unawaited(load());
    });
  }
  final WorkspaceProposalSource source;
  final Stream<WorkspaceRecordRef?> changes;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspaceProposalResults? results;
  WorkspaceProposalDetail? detail;
  WorkspaceCatalog? catalog;
  WorkspaceFailure? readFailure, writeFailure;
  WorkspaceProposalFilter filter = WorkspaceProposalFilter.all;
  WorkspaceProposalKind? kind;
  String keyword = '';
  int offset = 0, limit = 20, viewRevision = 0, _generation = 0;
  String? selection, notice;
  bool loading = false, reading = false, busy = false, _closed = false;
  double listScroll = 0;
  final _positions = <String, double>{};
  final _drafts = <String, ProposalDraft>{};
  WorkspaceProposalChange? _command;
  ProposalDraft? get draft => _drafts[selection];
  double get detailScroll => _positions[selection] ?? 0;
  set detailScroll(double value) {
    if (selection case final id?) _positions[id] = value;
  }

  bool get uncertain => writeFailure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get needsNewReview =>
      detail != null &&
      draft != null &&
      draft!.sourceFingerprint != detail!.snapshotDigest;
  List<WorkspaceProposalItem> get reviewItems => needsNewReview
      ? List.unmodifiable(draft!.originals.values)
      : detail?.items ?? const [];
  bool get needsReview =>
      detail != null &&
      draft != null &&
      (draft!.version != detail!.summary.version ||
          draft!.reviewToken != detail!.reviewToken ||
          needsNewReview);
  bool get _readable =>
      !_closed &&
      !frozen &&
      !loading &&
      !reading &&
      readFailure == null &&
      detail != null;
  bool get canConfirm =>
      _readable &&
      detail!.canConfirm &&
      draft != null &&
      !needsReview &&
      draft!.selected.isNotEmpty &&
      writeFailure?.code != 'conflict';
  bool get canReject => _readable && detail!.summary.pending;
  bool get canEdit =>
      _readable &&
      detail!.summary.pending &&
      detail!.summary.kind != WorkspaceProposalKind.deletion &&
      draft != null &&
      !needsNewReview;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _invalidateOwnerBefore(WorkspaceRecordRef? ref) {
    final d = detail;
    if (d == null ||
        !d.items.any(
          (i) =>
              i.before != null && (ref == null || i.before!.record.ref == ref),
        )) {
      return;
    }
    detail = WorkspaceProposalDetail(
      summary: d.summary,
      reviewToken: d.reviewToken,
      items: d.items.map(
        (i) => i.before != null && (ref == null || i.before!.record.ref == ref)
            ? i.withoutOwnerBefore()
            : i,
      ),
      targets: d.targets,
      notice: d.notice,
      currentTargetRef: d.currentTargetRef,
      currentAvailable: d.currentAvailable,
    );
    _notify();
  }

  WorkspaceProposalQuery _query({int? at}) => WorkspaceProposalQuery(
    keyword: keyword,
    filter: filter,
    kind: kind,
    offset: at ?? offset,
    limit: limit,
  );

  Future<void> load() async {
    if (_closed || frozen) return;
    final generation = ++_generation;
    loading = true;
    readFailure = null;
    _notify();
    try {
      var found = await source.query(_query(), keepSelection: selection);
      if (_closed || generation != _generation) return;
      if (filter == WorkspaceProposalFilter.pending &&
          selection != null &&
          found.selection != selection &&
          detail != null) {
        WorkspaceProposalDetail? old;
        try {
          old = await source.read(selection!);
        } on WorkspaceFailure catch (e) {
          if (e.code != 'not_found') rethrow;
          _drafts.remove(selection);
          _positions.remove(selection);
        }
        if (_closed || generation != _generation) return;
        if (old != null && !old.summary.pending) {
          filter = WorkspaceProposalFilter.all;
          notice = '所选提案已处理，正在显示它的结果。';
          found = await source.query(_query(), keepSelection: selection);
          if (_closed || generation != _generation) return;
        }
      }
      if (found.selectionIndex case final index?
          when index < found.offset || index >= found.offset + limit) {
        found = await source.query(
          _query(at: index ~/ limit * limit),
          keepSelection: found.selection,
        );
        if (_closed || generation != _generation) return;
      }
      results = found;
      offset = found.offset;
      if (selection != found.selection) detail = null;
      selection = found.selection;
      if (selection == null) {
        detail = null;
        return;
      }
      reading = true;
      _notify();
      final current = await source.read(selection!);
      final currentCatalog = await source.catalog();
      if (_closed || generation != _generation) return;
      detail = current;
      catalog = currentCatalog;
      if (!current.summary.pending) {
        _drafts.remove(current.summary.id);
      } else {
        _drafts.putIfAbsent(current.summary.id, () => ProposalDraft(current));
      }
    } catch (error) {
      if (!_closed && generation == _generation) {
        readFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法读取提案，请重试。');
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
    selection = id;
    detail = null;
    keyword = '';
    filter = WorkspaceProposalFilter.all;
    kind = null;
    offset = 0;
    listScroll = 0;
    viewRevision++;
    notice = null;
    writeFailure = null;
    await load();
  }

  Future<void> select(String id) async {
    if (frozen || _closed) return;
    selection = id;
    detail = null;
    notice = null;
    writeFailure = null;
    await load();
  }

  Future<void> _changeQuery(VoidCallback change) async {
    if (frozen || _closed) return;
    change();
    selection = null;
    detail = null;
    offset = 0;
    listScroll = 0;
    viewRevision++;
    notice = null;
    writeFailure = null;
    await load();
  }

  Future<void> search(String text) => _changeQuery(() => keyword = text);
  Future<void> setFilter(WorkspaceProposalFilter value) =>
      _changeQuery(() => filter = value);
  Future<void> setKind(WorkspaceProposalKind? value) =>
      _changeQuery(() => kind = value);
  Future<void> page(int value) async {
    if (frozen || _closed) return;
    offset = value;
    selection = null;
    detail = null;
    listScroll = 0;
    viewRevision++;
    writeFailure = null;
    await load();
  }

  void chooseItem(String id, bool selected) {
    if (!canEdit || !draft!.items.containsKey(id)) return;
    if (selected) {
      draft!.selected.add(id);
    } else {
      draft!.selected.remove(id);
    }
    draft!.dirty = true;
    if (writeFailure?.code != 'conflict') writeFailure = null;
    _notify();
  }

  bool editItem(
    String proposalId,
    int version,
    WorkspaceProposalItemReview review,
  ) {
    if (!canEdit ||
        selection != proposalId ||
        draft!.version != version ||
        detail!.summary.version != version ||
        !draft!.items.containsKey(review.itemId)) {
      return false;
    }
    draft!.items[review.itemId] = review;
    draft!.dirty = true;
    if (writeFailure?.code != 'conflict') writeFailure = null;
    _notify();
    return true;
  }

  Future<void> reviewCurrent() async {
    if (_closed || frozen) return;
    final id = selection, old = draft;
    await load();
    if (_closed ||
        selection != id ||
        readFailure != null ||
        old == null ||
        detail == null) {
      return;
    }
    if (!detail!.summary.pending) {
      writeFailure = null;
      notice = '提案已处理，正在显示结果。';
      _notify();
      return;
    }
    // A new proposal version requires a new review, not transplantation of an
    // old body onto new item/field identities. Fixed snapshots stay unchanged.
    if (old.sourceFingerprint != detail!.snapshotDigest ||
        old.version != detail!.summary.version ||
        !setEquals(
          old.items.keys.toSet(),
          detail!.items.map((i) => i.id).toSet(),
        )) {
      writeFailure = const WorkspaceFailure(
        'conflict',
        '提案版本或资料身份已变化；原审阅保留，不能自动套用。',
      );
      _notify();
      return;
    }
    old.reviewToken = detail!.reviewToken;
    writeFailure = null;
    notice = '已读取当前提案与分类，原选择和编辑仍保留；请核对后再决定。';
    _notify();
  }

  WorkspaceProposalReceipt _check(WorkspaceProposalReceipt r) {
    final c = _command!, d = detail!;
    final expected = c.action == WorkspaceProposalAction.reject
        ? 0
        : c.reviewed.length;
    final original = d.items.firstOrNull?.before;
    if (r.operationId != c.operationId ||
        r.proposalId != c.proposalId ||
        r.action != c.action ||
        r.reviewToken != c.reviewToken ||
        r.reviewedVersion != c.version ||
        r.resultingVersion <= c.version ||
        r.commandDigest != c.digest ||
        r.records.length != expected ||
        r.records.map((x) => x.ref).toSet().length != r.records.length ||
        r.records.any(
          (x) => x.ref.kind != WorkspaceRecordKind.information || x.version < 1,
        ) ||
        d.summary.kind == WorkspaceProposalKind.deletion &&
            c.action == WorkspaceProposalAction.confirm &&
            r.records.any((x) => x.entryId == null || x.entryId!.isEmpty) ||
        original != null &&
            r.records.isNotEmpty &&
            (r.records.single.ref != original.record.ref ||
                r.records.single.version <= original.version)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次提案决定不符，请继续核对原操作。');
    }
    return r;
  }

  Future<void> _finished(WorkspaceProposalReceipt r) async {
    busy = false;
    _command = null;
    writeFailure = null;
    _drafts.remove(r.proposalId);
    detail = null;
    _positions[r.proposalId] = 0;
    selection = r.proposalId;
    if (filter == WorkspaceProposalFilter.pending) {
      filter = WorkspaceProposalFilter.all;
    }
    notice = r.action == WorkspaceProposalAction.confirm
        ? '本次提案结果已记录。'
        : '已拒绝提案，信息库没有因此改变。';
    _notify();
    await load();
  }

  Future<void> decide(WorkspaceProposalAction action) async {
    if (action == WorkspaceProposalAction.confirm ? !canConfirm : !canReject) {
      return;
    }
    final d = detail!;
    _command = WorkspaceProposalChange(
      operationId: workspaceOperationId(),
      proposalId: d.summary.id,
      version: d.summary.version,
      reviewToken: action == WorkspaceProposalAction.confirm
          ? draft!.reviewToken
          : d.reviewToken,
      action: action,
      reviewed: action == WorkspaceProposalAction.reject
          ? []
          : [
              for (final i in d.items)
                if (draft!.selected.contains(i.id)) draft!.items[i.id]!,
            ],
    );
    busy = true;
    writeFailure = null;
    notice = null;
    _notify();
    try {
      final receipt = await source.change(_command!);
      if (!_closed) await _finished(_check(receipt));
    } catch (error) {
      if (!_closed) {
        busy = false;
        writeFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '提案结果暂时无法确认，请先核对原操作。');
        if (!uncertain) _command = null;
        _notify();
      }
    }
  }

  Future<void> reconcile() async {
    if (_closed || !uncertain || busy || _command == null) return;
    busy = true;
    _notify();
    try {
      final r = await source.receipt(_command!.operationId);
      if (_closed) return;
      if (r != null) {
        await _finished(_check(r));
      } else {
        busy = false;
        _command = null;
        writeFailure = null;
        notice = '已确认本次尚未提交，原选择和编辑仍保留；请核对后明确再次决定。';
        _notify();
        await load();
      }
    } catch (_) {
      if (!_closed) {
        busy = false;
        writeFailure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认本次提案结果，请稍后核对原操作。',
        );
        _notify();
      }
    }
  }

  void resetView() {
    if (frozen || _closed) return;
    _generation++;
    _drafts.clear();
    _positions.clear();
    selection = null;
    detail = null;
    results = null;
    readFailure = writeFailure = null;
    notice = null;
    keyword = '';
    filter = WorkspaceProposalFilter.all;
    kind = null;
    offset = 0;
    listScroll = 0;
    viewRevision++;
    unawaited(load());
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _drafts.clear();
    _positions.clear();
    _command = null;
    detail = null;
    results = null;
    catalog = null;
    readFailure = writeFailure = null;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
