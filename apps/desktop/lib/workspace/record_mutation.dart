import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

/// A single ordinary-record intent. Querying an uncertain result never writes.
class RecordMutation extends ChangeNotifier {
  RecordMutation(this.source);
  final WorkspaceSource source;
  bool busy = false, _closed = false;
  WorkspaceFailure? failure;
  String? _operation;
  WorkspaceOperationIntent? _intent;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get canSubmit => !frozen && failure?.code != 'conflict';

  void edited() {
    if (frozen || _closed) return;
    _operation = null;
    _intent = null;
    if (failure?.code != 'conflict') failure = null;
    notifyListeners();
  }

  void acceptCurrentVersion() {
    if (frozen || _closed) return;
    failure = null;
    _operation = null;
    _intent = null;
    notifyListeners();
  }

  WorkspaceRecordReceipt _check(WorkspaceOperationReceipt receipt) {
    final result = receipt.result, intent = _intent!;
    if (receipt.operationId != _operation ||
        !intent.matches(receipt.intent) ||
        result.ref.kind != WorkspaceRecordKind.information ||
        intent.ref != null && result.ref != intent.ref ||
        result.version <= (intent.expectedVersion ?? 0)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次操作不符，请继续核对结果。');
    }
    return result;
  }

  Future<WorkspaceRecordReceipt?> submit(
    WorkspaceOperationIntent intent,
    Future<WorkspaceRecordReceipt> Function(String operationId) write,
  ) async {
    if (!canSubmit || _closed) return null;
    _operation = workspaceOperationId();
    _intent = intent;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final result = await write(_operation!);
      final checked = _check(
        WorkspaceOperationReceipt(
          operationId: _operation!,
          intent: intent,
          result: result,
        ),
      );
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
      return checked;
    } catch (error) {
      if (!_closed) {
        busy = false;
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对结果。');
        if (!uncertain) {
          _operation = null;
          _intent = null;
        }
        notifyListeners();
      }
      return null;
    }
  }

  Future<WorkspaceRecordReceipt?> reconcile() async {
    if (!uncertain || busy || _operation == null || _closed) return null;
    busy = true;
    notifyListeners();
    try {
      final receipt = await source.recordOperationReceipt(_operation!);
      final result = receipt == null ? null : _check(receipt);
      if (!_closed) {
        busy = false;
        failure = null;
        _operation = null;
        _intent = null;
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
