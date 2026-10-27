import 'package:flutter/material.dart';
import 'workspace_source.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this.source);
  final WorkspaceSource source;
  WorkspaceLocation location = const WorkspaceLocation(WorkspacePage.library);
  Brightness brightness = Brightness.light;
  WorkspaceLoad load = WorkspaceLoad.idle;
  WorkspaceSummary? summary;
  WorkspaceFailure? failure;
  final _back = <WorkspaceLocation>[];
  final _locations = <WorkspacePage, WorkspaceLocation>{};
  int _generation = 0;
  bool _closed = false;
  bool navigationLocked = false;
  void setNavigationLocked(bool value) {
    if (_closed || navigationLocked == value) return;
    navigationLocked = value;
    notifyListeners();
  }

  bool get canGoBack => _back.isNotEmpty;
  WorkspacePage? get previousPage => _back.isEmpty ? null : _back.last.page;

  void navigate(
    WorkspacePage page, {
    String? objectId,
    bool remember = false,
    WorkspaceQuery? query,
    double? scrollOffset,
    bool clearSelection = false,
  }) {
    if (_closed || navigationLocked) return;
    if (remember) _back.add(location);
    _locations[location.page] = location;
    final prior = _locations[page];
    location = WorkspaceLocation(
      page,
      objectId: clearSelection ? null : objectId ?? prior?.objectId,
      query: query ?? prior?.query,
      scrollOffset: scrollOffset ?? prior?.scrollOffset ?? 0,
    );
    notifyListeners();
  }

  void goBack() {
    if (_closed || navigationLocked || _back.isEmpty) return;
    location = _back.removeLast();
    notifyListeners();
  }

  void setBrightness(Brightness value) {
    if (_closed || value == brightness) return;
    brightness = value;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_closed) return;
    final generation = ++_generation;
    load = WorkspaceLoad.loading;
    failure = null;
    notifyListeners();
    try {
      final result = await source.loadSummary();
      if (_closed || generation != _generation) return;
      summary = result;
      load = result.isEmpty ? WorkspaceLoad.empty : WorkspaceLoad.ready;
    } on WorkspaceFailure catch (error) {
      if (_closed || generation != _generation) return;
      failure = error;
      load = WorkspaceLoad.error;
    } catch (_) {
      if (_closed || generation != _generation) return;
      failure = const WorkspaceFailure('unavailable', '暂时无法读取，请稍后重试。');
      load = WorkspaceLoad.error;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    super.dispose();
  }
}
