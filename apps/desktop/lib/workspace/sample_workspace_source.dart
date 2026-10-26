import 'dart:async';
import 'workspace_source.dart';

enum SampleWorkspaceScenario { ready, empty, waiting, failure }

/// Explicitly instantiated by preview_main only. Production has no fallback
/// reference to this provider. Scenarios use observable completion, not sleeps.
class SampleWorkspaceSource implements WorkspaceSource {
  SampleWorkspaceScenario _scenario = SampleWorkspaceScenario.ready;
  final _waiting = <Completer<WorkspaceSummary>>[];
  static const initial = WorkspaceSummary(
    records: 31,
    pending: 5,
    proposals: 2,
  );
  SampleWorkspaceScenario get scenario => _scenario;

  void setScenario(SampleWorkspaceScenario value) {
    for (final request in _waiting) {
      request.completeError(const WorkspaceFailure('cancelled', '已切换预览状态。'));
    }
    _waiting.clear();
    _scenario = value;
  }

  @override
  Future<WorkspaceSummary> loadSummary() async {
    switch (_scenario) {
      case SampleWorkspaceScenario.ready:
        return initial;
      case SampleWorkspaceScenario.empty:
        return const WorkspaceSummary.empty();
      case SampleWorkspaceScenario.failure:
        throw const WorkspaceFailure('sample_unavailable', '暂时无法读取资料，请重试。');
      case SampleWorkspaceScenario.waiting:
        final result = Completer<WorkspaceSummary>();
        _waiting.add(result);
        return result.future;
    }
  }

  void reset() => setScenario(SampleWorkspaceScenario.ready);
  void dispose() => setScenario(SampleWorkspaceScenario.ready);
}
