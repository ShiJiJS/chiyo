import 'workspace_records_controller.dart';
import 'workspace_source.dart';

/// Library navigation owns query/selection/return state. It never reads a
/// related record's body merely to decide whether a filter includes it.
class LibraryController extends WorkspaceRecordsController {
  LibraryController(super.source) {
    query = const WorkspaceQuery(directoryId: 'selfhost');
  }
  final _back =
      <({WorkspaceQuery query, WorkspaceRecordRef? selected, double scroll})>[];
  int _navigation = 0;
  bool _closed = false;
  String? navigationNotice;
  int searchFocusRequest = 0, viewReset = 0;
  bool get canGoBack => _back.isNotEmpty;

  Future<void> resetView() {
    viewReset++;
    ++_navigation;
    _back.clear();
    scrollOffset = 0;
    navigationNotice = null;
    selection = null;
    detail = null;
    return load(
      const WorkspaceQuery(directoryId: 'selfhost'),
      keepSelection: const WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'azure',
      ),
    );
  }

  void focusSearch() {
    if (_closed) return;
    searchFocusRequest++;
    notifyListeners();
  }

  Future<void> apply(WorkspaceQuery next) {
    ++_navigation;
    scrollOffset = 0;
    navigationNotice = null;
    return load(next.copyWith(offset: 0));
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
