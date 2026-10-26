import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class HostMutation extends ChangeNotifier {
  HostMutation(this.source);
  final WorkspaceHostSource source;
  WorkspaceHostChange? _command;
  WorkspaceFailure? failure;
  bool busy = false, _closed = false;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get canSubmit => !frozen && failure?.code != 'conflict';
  void reviewed() {
    if (_closed || frozen) return;
    failure = null;
    _command = null;
    notifyListeners();
  }

  WorkspaceHostReceipt _check(WorkspaceHostReceipt r) {
    final c = _command!;
    if (r.operationId != c.operationId ||
        r.action != c.action ||
        r.identityId != c.reviewed.identityId ||
        r.targetKey != c.reviewed.target.key ||
        r.expectedRecordVersion != c.reviewed.recordVersion ||
        r.expectedPluginVersion != c.reviewed.pluginVersion ||
        r.expectedVersion != c.reviewed.version ||
        r.version <= r.expectedVersion) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次主机身份操作不符，请继续核对。');
    }
    return r;
  }

  Future<WorkspaceHostReceipt?> submit(
    WorkspaceHostIdentity seen,
    WorkspaceHostAction action, {
    bool acknowledgeChanged = false,
  }) async {
    if (_closed || !canSubmit) return null;
    _command = WorkspaceHostChange(
      operationId: workspaceOperationId(),
      action: action,
      reviewed: seen,
      acknowledgeChanged: acknowledgeChanged,
    );
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final receipt = _check(await source.change(_command!));
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
      return receipt;
    } catch (e) {
      if (!_closed) {
        busy = false;
        failure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对。');
        if (!uncertain) _command = null;
        notifyListeners();
      }
      return null;
    }
  }

  Future<WorkspaceHostReceipt?> reconcile() async {
    if (_closed || busy || !uncertain || _command == null) return null;
    busy = true;
    notifyListeners();
    try {
      final receipt = await source.receipt(_command!.operationId);
      final result = receipt == null ? null : _check(receipt);
      if (!_closed) {
        busy = false;
        failure = null;
        _command = null;
        notifyListeners();
      }
      return result;
    } catch (_) {
      if (!_closed) {
        busy = false;
        failure = const WorkspaceFailure('unknown_outcome', '仍无法确认结果，请稍后核对。');
        notifyListeners();
      }
      return null;
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
