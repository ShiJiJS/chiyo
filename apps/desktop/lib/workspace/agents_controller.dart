import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class WorkspaceAgentsController extends ChangeNotifier {
  WorkspaceAgentsController(this.source, Stream<WorkspaceRecordRef?> changes) {
    _changes = changes.listen((_) {
      _invalidateDetails();
      unawaited(load());
    });
  }
  final WorkspaceAgentsSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _changes;
  WorkspaceAgentOverview? value, report;
  String? selectedSessionId;
  Future<void> selectSession(String? id) async {
    selectedSessionId = id;
    await load();
  }

  WorkspaceAgentSessionDetail? session;
  WorkspaceAgentView? view;
  WorkspaceFailure? readFailure, detailFailure;
  bool loading = false, detailBusy = false, _closed = false;
  int _generation = 0, _detailGeneration = 0, _viewGeneration = 0;
  bool get available => !loading && value != null && readFailure == null;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  WorkspaceFailure _error(Object e, String message) =>
      e is WorkspaceFailure && e.code != 'unknown_outcome'
      ? e
      : WorkspaceFailure('unavailable', message);
  void _invalidateDetails() {
    _detailGeneration++;
    report = null;
    session = null;
    detailFailure = null;
    detailBusy = false;
  }

  Future<void> load({bool refreshDetails = true}) async {
    if (_closed) return;
    final generation = ++_generation;
    _invalidateDetails();
    loading = true;
    readFailure = null;
    _notify();
    try {
      final next = await source.read(sessionId: selectedSessionId);
      if (!next.valid) {
        throw const WorkspaceFailure('invalid_observation', '接入观察无法确认，请重新检测。');
      }
      if (!_closed && generation == _generation) value = next;
    } catch (error) {
      if (!_closed && generation == _generation) {
        readFailure = _error(error, '接入状态暂时无法读取，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
    if (!_closed &&
        generation == _generation &&
        refreshDetails &&
        {
          WorkspaceAgentView.diagnostics,
          WorkspaceAgentView.session,
        }.contains(view)) {
      await readDetails();
    }
  }

  void open(WorkspaceAgentView next) {
    if (_closed) return;
    _invalidateDetails();
    _viewGeneration++;
    view = next;
    _notify();
  }

  void close() {
    if (_closed) return;
    _viewGeneration++;
    view = null;
    _invalidateDetails();
    _notify();
  }

  Future<void> readDetails() async {
    final target = view, viewGeneration = _viewGeneration;
    if (_closed ||
        detailBusy ||
        !{
          WorkspaceAgentView.diagnostics,
          WorkspaceAgentView.session,
        }.contains(target)) {
      return;
    }
    if (!available) {
      await load(refreshDetails: false);
      if (_closed ||
          view != target ||
          viewGeneration != _viewGeneration ||
          loading) {
        return;
      }
      if (!available) {
        detailFailure =
            readFailure ?? const WorkspaceFailure('unavailable', '接入观察尚未就绪。');
        _notify();
        return;
      }
    }
    final generation = ++_detailGeneration, expected = value!;
    detailBusy = true;
    detailFailure = null;
    report = null;
    session = null;
    _notify();
    try {
      if (target == WorkspaceAgentView.diagnostics) {
        final next = await source.diagnose(expected.version);
        if (!next.valid || next.fingerprint != expected.fingerprint) {
          throw const WorkspaceFailure(
            'observation_changed',
            '诊断与当前接入观察不符，请重新检测。',
          );
        }
        if (!_closed && generation == _detailGeneration && view == target) {
          report = next;
        }
      } else {
        final next = await source.currentSession(expected.version);
        if (!next.matches(expected)) {
          throw const WorkspaceFailure(
            'observation_changed',
            '聊天关联与当前观察不符，请重新检测。',
          );
        }
        if (!_closed && generation == _detailGeneration && view == target) {
          session = next;
        }
      }
    } catch (error) {
      if (!_closed && generation == _detailGeneration && view == target) {
        detailFailure = _error(error, '接入详情读取失败，请重试。');
      }
    } finally {
      if (!_closed && generation == _detailGeneration) {
        detailBusy = false;
        _notify();
      }
    }
  }

  Future<void> retryDetails() => load();
  @override
  void dispose() {
    _closed = true;
    _generation++;
    _detailGeneration++;
    _viewGeneration++;
    unawaited(_changes.cancel());
    super.dispose();
  }
}
