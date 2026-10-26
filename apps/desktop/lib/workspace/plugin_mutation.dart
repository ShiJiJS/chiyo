import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class PluginMutation extends ChangeNotifier {
  PluginMutation(this.source);
  final WorkspacePluginSource source;
  WorkspacePluginChange? _command;
  WorkspaceFailure? failure;
  bool busy = false, _closed = false;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get canSubmit => !frozen && failure?.code != 'conflict';
  void reviewed() {
    if (frozen || _closed) return;
    _command = null;
    failure = null;
    notifyListeners();
  }

  WorkspacePluginReceipt _check(WorkspacePluginReceipt receipt) {
    final c = _command!;
    if (receipt.operationId != c.operationId ||
        receipt.action != c.action ||
        receipt.packageId != c.packageId ||
        receipt.expectedVersion != c.expectedVersion ||
        receipt.version <= c.expectedVersion ||
        c.action == WorkspacePluginAction.install &&
            receipt.digest != c.expectedDigest) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次插件操作不符，请继续核对。');
    }
    return receipt;
  }

  Future<WorkspacePluginReceipt?> submit(
    WorkspacePluginChange Function(String) build,
  ) async {
    if (!canSubmit || _closed) return null;
    _command = build(workspaceOperationId());
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final result = _check(await source.change(_command!));
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
      return result;
    } catch (error) {
      if (!_closed) {
        busy = false;
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对结果。');
        if (!uncertain) _command = null;
        notifyListeners();
      }
      return null;
    }
  }

  Future<WorkspacePluginReceipt?> reconcile() async {
    if (!uncertain || busy || _closed || _command == null) return null;
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
