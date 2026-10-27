import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class LegacyTemplatesController extends ChangeNotifier {
  LegacyTemplatesController(this.source, Stream<WorkspaceRecordRef?> changes) {
    _subscription = changes.listen((_) => unawaited(load()));
  }
  final WorkspaceLegacyTemplateSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  List<WorkspaceLegacyTemplate>? templates;
  WorkspaceFailure? failure;
  bool loading = false, _closed = false;
  int _generation = 0;
  String? selection;
  double scrollOffset = 0;
  WorkspaceLegacyTemplate? get selected =>
      templates?.where((t) => t.id == selection).firstOrNull;
  Future<void> load() async {
    if (_closed) return;
    final generation = ++_generation;
    loading = true;
    failure = null;
    notifyListeners();
    try {
      final result = await source.load();
      if (_closed || generation != _generation) return;
      templates = result;
      if (!result.any((t) => t.id == selection)) {
        selection = result.firstOrNull?.id;
        scrollOffset = 0;
      }
    } catch (e) {
      if (!_closed && generation == _generation) {
        failure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unavailable', '旧版模板暂不可用，请重新读取。');
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
