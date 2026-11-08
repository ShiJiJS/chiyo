import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

enum WorkspaceSaveState { idle, saving, saved, rejected }

/// Owns the query/selection projection and its async lifetime. Forms retain
/// their drafts; a failed or stale save never writes back into those drafts.
class WorkspaceRecordsController extends ChangeNotifier {
  WorkspaceRecordsController(this.source) {
    _subscription = source.changes.listen((_) {
      if (!_disposed && saveState != WorkspaceSaveState.saving) {
        unawaited(load(query, keepSelection: selection));
      }
    });
  }
  final WorkspaceSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspaceQuery query = const WorkspaceQuery();
  WorkspaceCatalog? catalog;
  WorkspaceResults? results;
  WorkspaceRecordRef? selection;
  WorkspaceDetail? detail;
  WorkspaceFailure? failure, detailFailure, saveFailure;
  String? scopeNotice;
  WorkspaceLoad loadState = WorkspaceLoad.idle;
  WorkspaceSaveState saveState = WorkspaceSaveState.idle;
  double scrollOffset = 0;
  int revision = 0;
  int _queryGeneration = 0, _detailGeneration = 0;
  bool _disposed = false;
  Future<void>? _latestRead;

  Future<void> load(WorkspaceQuery next, {WorkspaceRecordRef? keepSelection}) {
    if (_disposed) return Future.value();
    final read = _load(next, keepSelection: keepSelection);
    _latestRead = read;
    return _settle(read);
  }

  Future<void> _settle(Future<void> read) async {
    await read;
    while (!_disposed && !identical(_latestRead, read)) {
      read = _latestRead!;
      await read;
    }
  }

  Future<void> _load(
    WorkspaceQuery next, {
    WorkspaceRecordRef? keepSelection,
  }) async {
    if (_disposed) return;
    final generation = ++_queryGeneration;
    ++_detailGeneration;
    query = next;
    loadState = WorkspaceLoad.loading;
    failure = null;
    detailFailure = null;
    notifyListeners();
    try {
      final currentCatalog = await source.loadCatalog();
      if (_disposed || generation != _queryGeneration) return;
      final lostDirectory =
          next.directoryId != null &&
          !{'all', 'unfiled'}.contains(next.directoryId) &&
          !currentCatalog.directories.any((d) => d.id == next.directoryId);
      final lostTag =
          next.tagId != null &&
          !currentCatalog.tags.any((t) => t.id == next.tagId);
      scopeNotice = lostDirectory || lostTag ? '原目录或标签已移除，已清除失效的筛选条件。' : null;
      if (lostDirectory || lostTag) {
        next = next.copyWith(
          clearDirectory: lostDirectory,
          clearTag: lostTag,
          offset: 0,
        );
        query = next;
        scrollOffset = 0;
      }
      final value = await source.queryRecords(
        next,
        keepSelection: keepSelection ?? selection,
      );
      if (_disposed || generation != _queryGeneration) return;
      catalog = currentCatalog;
      results = value;
      if (query.offset != value.offset) {
        query = query.copyWith(offset: value.offset);
        scrollOffset = 0;
      }
      revision++;
      selection = value.selection;
      if (selection == null) detail = null;
      projectionLoaded();
      loadState = value.total == 0 ? WorkspaceLoad.empty : WorkspaceLoad.ready;
      notifyListeners();
      if (selection != null) await select(selection!);
    } on WorkspaceFailure catch (error) {
      if (_disposed || generation != _queryGeneration) return;
      failure = error;
      loadState = WorkspaceLoad.error;
      notifyListeners();
    } catch (_) {
      if (_disposed || generation != _queryGeneration) return;
      failure = const WorkspaceFailure('unavailable', '暂时无法读取，请稍后重试。');
      loadState = WorkspaceLoad.error;
      notifyListeners();
    }
  }

  /// Subclasses reconcile view-only state before the new rows become
  /// interactive. A selection from an old page must not survive until the
  /// unrelated detail read finishes.
  @protected
  void projectionLoaded() {}

  Future<void> select(WorkspaceRecordRef ref) async {
    if (_disposed) return;
    final generation = ++_detailGeneration;
    if (detail?.record.ref != ref) detail = null;
    selection = ref;
    detailFailure = null;
    notifyListeners();
    try {
      final value = await source.readDetail(ref);
      if (_disposed || generation != _detailGeneration) return;
      detail = value;
      notifyListeners();
    } on WorkspaceFailure catch (error) {
      if (_disposed || generation != _detailGeneration) return;
      detailFailure = error;
      if (error.code == 'not_found') detail = null;
      notifyListeners();
    } catch (_) {
      if (_disposed || generation != _detailGeneration) return;
      detailFailure = const WorkspaceFailure('unavailable', '暂时无法读取资料。');
      notifyListeners();
    }
  }

  Future<WorkspaceSaveResult> save(WorkspaceEdit edit) async {
    if (_disposed || saveState == WorkspaceSaveState.saving) {
      return const WorkspaceRejected(WorkspaceFailure('busy', '已有保存进行中。'));
    }
    saveState = WorkspaceSaveState.saving;
    saveFailure = null;
    notifyListeners();
    WorkspaceSaveResult result;
    try {
      result = await source.saveRecord(edit);
    } on WorkspaceFailure catch (failure) {
      result = WorkspaceRejected(failure);
    } catch (_) {
      result = const WorkspaceRejected(
        WorkspaceFailure('unknown_outcome', '保存结果暂时无法确认，请重新读取后核对，不要重复提交。'),
      );
    }
    if (_disposed) return result;
    switch (result) {
      case WorkspaceSaved():
        // Keep suppressing this writer's change notification while refreshing.
        await load(query, keepSelection: selection);
        if (_disposed) return result;
        saveState = WorkspaceSaveState.saved;
      case WorkspaceRejected(:final failure):
        saveFailure = failure;
        saveState = WorkspaceSaveState.rejected;
    }
    notifyListeners();
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_queryGeneration;
    ++_detailGeneration;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
