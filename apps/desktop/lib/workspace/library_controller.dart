import 'workspace_records_controller.dart';
import 'workspace_source.dart';

/// Library navigation owns query/selection/return state. It never reads a
/// related record's body merely to decide whether a filter includes it.
class LibraryController extends WorkspaceRecordsController {
  LibraryController(
    super.source, {
    WorkspaceQuery? initialQuery,
    this.initialSelection,
  }) : _initialQuery = initialQuery {
    query = this.initialQuery;
  }
  final WorkspaceQuery? _initialQuery;
  WorkspaceQuery get initialQuery =>
      _initialQuery ??
      WorkspaceQuery(
        sort: source is WorkspaceLibraryMove
            ? (source as WorkspaceLibraryMove).preferredLibrarySort ??
                  WorkspaceSort.updated
            : WorkspaceSort.updated,
      );
  String? sortPreferenceNotice;
  final WorkspaceRecordRef? initialSelection;
  final _back =
      <({WorkspaceQuery query, WorkspaceRecordRef? selected, double scroll})>[];
  int _navigation = 0;
  bool _closed = false;
  String? navigationNotice;
  int searchFocusRequest = 0, viewReset = 0;
  bool get canGoBack => _back.isNotEmpty;
  bool selecting = false;
  String? selectionNotice;
  final _selectedRecords = <WorkspaceRecordRef>{};
  final _selectedDirectories = <String>{};
  int get selectedCount =>
      _selectedRecords.length + _selectedDirectories.length;
  bool get selectionAvailable =>
      catalog != null &&
      (loadState == WorkspaceLoad.ready || loadState == WorkspaceLoad.empty);
  bool recordIsSelected(WorkspaceRecordRef ref) =>
      _selectedRecords.contains(ref);
  bool directoryIsSelected(String id) => _selectedDirectories.contains(id);
  WorkspaceLibrarySelection get selectedBatch => WorkspaceLibrarySelection(
    directoryIds: _selectedDirectories,
    records: _selectedRecords,
  );
  WorkspaceLibrarySelection selectionForRecord(WorkspaceRecordRef ref) =>
      selecting && recordIsSelected(ref)
      ? selectedBatch
      : WorkspaceLibrarySelection(records: [ref]);
  WorkspaceLibrarySelection selectionForDirectory(String id) =>
      selecting && directoryIsSelected(id)
      ? selectedBatch
      : WorkspaceLibrarySelection(directoryIds: [id]);

  void beginSelection() {
    if (_closed || !selectionAvailable) return;
    selecting = true;
    selectionNotice = null;
    notifyListeners();
  }

  void cancelSelection() {
    if (_closed) return;
    selecting = false;
    _selectedRecords.clear();
    _selectedDirectories.clear();
    selectionNotice = null;
    notifyListeners();
  }

  void toggleRecord(WorkspaceRecordRef ref) {
    if (_closed ||
        !selectionAvailable ||
        results?.items.any((r) => r.ref == ref) != true) {
      return;
    }
    selecting = true;
    if (!_selectedRecords.add(ref)) _selectedRecords.remove(ref);
    selectionNotice = null;
    notifyListeners();
  }

  void toggleDirectory(String id) {
    if (_closed ||
        !selectionAvailable ||
        {'all', 'unfiled'}.contains(id) ||
        catalog?.directories.any((d) => d.id == id) != true) {
      return;
    }
    selecting = true;
    if (!_selectedDirectories.add(id)) _selectedDirectories.remove(id);
    selectionNotice = null;
    notifyListeners();
  }

  void selectDisplayedRecords() {
    if (_closed || !selectionAvailable) return;
    selecting = true;
    _selectedRecords.addAll(results!.items.map((r) => r.ref));
    selectionNotice = null;
    notifyListeners();
  }

  Object _scopeKey(WorkspaceQuery q) => (
    q.directoryId,
    q.keyword,
    q.typeId,
    q.tagId,
    q.grouping,
    q.sort,
    q.offset,
    q.limit,
  );

  @override
  Future<void> load(
    WorkspaceQuery next, {
    WorkspaceRecordRef? keepSelection,
    bool background = false,
  }) {
    if (_scopeKey(next) != _scopeKey(query) && selectedCount > 0) {
      _selectedRecords.clear();
      _selectedDirectories.clear();
      selectionNotice = '显示范围已改变，已清除多选。';
    }
    return super.load(
      next,
      keepSelection: keepSelection,
      background: background,
    );
  }

  @override
  void projectionLoaded() {
    final before = selectedCount;
    final displayed = results!.items.map((r) => r.ref).toSet();
    final directories = catalog!.directories.map((d) => d.id).toSet();
    _selectedRecords.removeWhere((r) => !displayed.contains(r));
    _selectedDirectories.removeWhere((id) => !directories.contains(id));
    if (selectedCount != before) {
      selectionNotice = '显示结果已更新，已移除不在当前范围的选择。';
    }
  }

  Future<void> resetView() {
    cancelSelection();
    viewReset++;
    ++_navigation;
    _back.clear();
    scrollOffset = 0;
    navigationNotice = null;
    selection = null;
    detail = null;
    return load(initialQuery, keepSelection: initialSelection);
  }

  void focusSearch() {
    if (_closed) return;
    searchFocusRequest++;
    notifyListeners();
  }

  Future<void> apply(WorkspaceQuery next) async {
    final navigation = ++_navigation;
    if (next.sort != query.sort && source is WorkspaceLibraryMove) {
      try {
        await (source as WorkspaceLibraryMove).saveLibrarySort(next.sort);
        sortPreferenceNotice = null;
      } catch (_) {
        sortPreferenceNotice = '显示方式未能记住，重开后请重新选择。';
      }
      if (_closed || navigation != _navigation) return;
    }
    scrollOffset = 0;
    navigationNotice = null;
    await load(next.copyWith(offset: 0));
  }

  Future<void> clearFilters() =>
      apply(query.copyWith(keyword: '', clearType: true, clearTag: true));

  Future<void> showAll() => apply(
    query.copyWith(
      clearDirectory: true,
      keyword: '',
      clearType: true,
      clearTag: true,
    ),
  );

  Future<void> openRelated(
    WorkspaceRecordRef ref, {
    bool rememberOrigin = true,
  }) async {
    final generation = ++_navigation;
    final origin = (query: query, selected: selection, scroll: scrollOffset);
    try {
      final all = await source.queryRecords(
        const WorkspaceQuery(limit: 1),
        keepSelection: ref,
      );
      if (_closed || generation != _navigation) return;
      if (all.selection != ref) {
        navigationNotice = '关联资料已不存在，请核对原资料。';
        notifyListeners();
        return;
      }
      final probes = <({String name, WorkspaceQuery query})>[
        if (query.directoryId != null)
          (
            name: 'directory',
            query: WorkspaceQuery(directoryId: query.directoryId, limit: 1),
          ),
        if (query.keyword.isNotEmpty)
          (
            name: 'keyword',
            query: WorkspaceQuery(keyword: query.keyword, limit: 1),
          ),
        if (query.typeId != null)
          (name: 'type', query: WorkspaceQuery(typeId: query.typeId, limit: 1)),
        if (query.tagId != null)
          (name: 'tag', query: WorkspaceQuery(tagId: query.tagId, limit: 1)),
      ];
      final outcomes = await Future.wait(
        probes.map((p) => source.queryRecords(p.query, keepSelection: ref)),
      );
      if (_closed || generation != _navigation) return;
      final blocked = <String>{
        for (var i = 0; i < probes.length; i++)
          if (outcomes[i].selection != ref) probes[i].name,
      };
      var next = query.copyWith(
        clearDirectory: blocked.contains('directory'),
        keyword: blocked.contains('keyword') ? '' : query.keyword,
        clearType: blocked.contains('type'),
        clearTag: blocked.contains('tag'),
      );
      final projection = await source.queryRecords(next, keepSelection: ref);
      if (_closed || generation != _navigation) return;
      final index = projection.selectionIndex;
      if (projection.selection != ref || index == null) {
        navigationNotice = '关联资料已变化，请重新打开。';
        notifyListeners();
        return;
      }
      next = next.copyWith(offset: index ~/ next.limit * next.limit);
      if (rememberOrigin) _back.add(origin);
      scrollOffset = 0;
      navigationNotice = blocked.isEmpty
          ? null
          : rememberOrigin
          ? '已调整范围以显示关联资料；可返回原查询。'
          : '已调整范围以显示保存后的资料。';
      await load(next, keepSelection: ref);
    } on WorkspaceFailure catch (error) {
      if (_closed || generation != _navigation) return;
      navigationNotice = error.message;
      notifyListeners();
    } catch (_) {
      if (_closed || generation != _navigation) return;
      navigationNotice = '暂时无法打开关联资料，请重试。';
      notifyListeners();
    }
  }

  Future<void> goBack() async {
    ++_navigation;
    if (_closed || _back.isEmpty) return;
    final prior = _back.removeLast();
    scrollOffset = prior.scroll;
    navigationNotice = null;
    await load(prior.query, keepSelection: prior.selected);
  }

  @override
  void dispose() {
    _closed = true;
    ++_navigation;
    super.dispose();
  }
}
