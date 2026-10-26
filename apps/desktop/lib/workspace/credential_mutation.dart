import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

/// A form's submission lifetime. An uncertain result freezes that intent until
/// the source confirms commitment or absence; no automatic write retry.
class CredentialMutation extends ChangeNotifier {
  CredentialMutation(this.source, {this.expectedRef});
  final WorkspaceCredentialSource source;
  final WorkspaceRecordRef? expectedRef;
  bool busy = false, _closed = false;
  WorkspaceFailure? failure;
  String? _operation;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get canSubmit => !busy && !uncertain && failure?.code != 'conflict';
  void markUncertain(String message) {
    if (_closed) return;
    busy = false;
    failure = WorkspaceFailure('unknown_outcome', message);
    notifyListeners();
  }

  void edited() {
    if (busy || uncertain) return;
    _operation = null;
    if (failure?.code != 'conflict') failure = null;
    notifyListeners();
  }

  void acceptCurrentVersion() {
    if (busy || uncertain) return;
    _operation = null;
    failure = null;
    notifyListeners();
  }

  WorkspaceCredentialReceipt _check(WorkspaceCredentialReceipt receipt) {
    if (receipt.ref.kind != WorkspaceRecordKind.credential ||
        expectedRef != null && receipt.ref != expectedRef) {
      throw const WorkspaceFailure('unknown_outcome', '操作回执与当前凭据不符，请先核对。');
    }
    return receipt;
  }

  Future<WorkspaceCredentialReceipt?> submit(
    Future<WorkspaceCredentialReceipt> Function(String operationId) write,
  ) async {
    if (!canSubmit || _closed) return null;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final receipt = _check(
        await write(_operation ??= workspaceOperationId()),
      );
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
      return receipt;
    } catch (error) {
      if (!_closed) {
        busy = false;
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对。');
        if (!uncertain) _operation = null;
        notifyListeners();
      }
      return null;
    }
  }

  Future<WorkspaceCredentialReceipt?> reconcile() async {
    if (!uncertain || busy || _operation == null || _closed) return null;
    busy = true;
    notifyListeners();
    try {
      final result = await source.receipt(_operation!);
      final checked = result == null ? null : _check(result);
      if (!_closed) {
        busy = false;
        failure = null;
        _operation = null;
        notifyListeners();
      }
      return checked;
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
