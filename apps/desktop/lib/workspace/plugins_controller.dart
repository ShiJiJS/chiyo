import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

enum PluginFilter {
  all('全部'),
  enabled('已启用'),
  disabled('已停用');

  const PluginFilter(this.label);
  final String label;
}

enum PluginTab {
  preview('模板预览'),
  structure('字段与关联'),
  settings('插件设置'),
  instructions('Agent 录入说明');

  const PluginTab(this.label);
  final String label;
}

/// Metadata-only projection retained by the composition root across navigation.
class PluginsController extends ChangeNotifier {
  PluginsController(this.source, Stream<WorkspaceRecordRef?> changes) {
    _subscription = changes.listen((_) => unawaited(load()));
  }
  final WorkspacePluginSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspacePluginCatalog? catalog;
  WorkspaceFailure? failure;
  bool loading = false, _closed = false;
  int _generation = 0;
  int get readGeneration => _generation;
  PluginFilter filter = PluginFilter.all;
  PluginTab tab = PluginTab.preview;
  String? selection, templateId;
  double scrollOffset = 0;
  WorkspaceHostTarget? pendingHost;
  void showHostSettings(WorkspaceHostTarget? target) {
    filter = PluginFilter.all;
    selection = 'builtin.server';
    templateId = null;
    tab = PluginTab.settings;
    scrollOffset = 0;
    pendingHost = target;
    notifyListeners();
  }

  WorkspaceHostTarget? takeHostRequest() {
    final result = pendingHost;
    pendingHost = null;
    return result;
  }

  List<WorkspacePlugin> get visible => [
    for (final p in catalog?.packages ?? <WorkspacePlugin>[])
      if (filter == PluginFilter.all ||
          p.enabled == (filter == PluginFilter.enabled))
        p,
  ];
  WorkspacePlugin? get selected =>
      catalog?.packages.where((p) => p.id == selection).firstOrNull;
  WorkspacePluginTemplate? get selectedTemplate =>
      selected?.templates.where((t) => t.id == templateId).firstOrNull ??
      selected?.templates.firstOrNull;
  Future<void> load() async {
    if (_closed) return;
    final generation = ++_generation;
    loading = true;
    failure = null;
    notifyListeners();
    try {
      final value = await source.load();
      if (_closed || generation != _generation) return;
      catalog = value;
      if (!visible.any((p) => p.id == selection)) {
        selection = visible.firstOrNull?.id;
        templateId = null;
        tab = PluginTab.preview;
        scrollOffset = 0;
      }
    } on WorkspaceFailure catch (error) {
      if (!_closed && generation == _generation) failure = error;
    } catch (_) {
      if (!_closed && generation == _generation) {
        failure = const WorkspaceFailure('unavailable', '暂时无法读取插件，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void select(String id) {
    if (_closed) return;
    selection = id;
    templateId = null;
    tab = PluginTab.preview;
    scrollOffset = 0;
    notifyListeners();
  }

  void setFilter(PluginFilter value) {
    filter = value;
    if (!visible.any((p) => p.id == selection)) {
      selection = visible.firstOrNull?.id;
      templateId = null;
      tab = PluginTab.preview;
    }
    notifyListeners();
  }

  void setTab(PluginTab value) {
    tab = value;
    scrollOffset = 0;
    notifyListeners();
  }

  void selectTemplate(String id) {
    templateId = id;
    scrollOffset = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
