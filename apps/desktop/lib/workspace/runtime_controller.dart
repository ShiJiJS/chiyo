import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class WorkspaceRuntimeController extends ChangeNotifier {
  WorkspaceRuntimeController(this.source, Stream<WorkspaceRecordRef?> changes) {
    _changes = changes.listen((_) {
      if (frozen) return;
      if (quitPreview != null) {
        unawaited(_release());
        failure = const WorkspaceFailure(
          'quit_changed',
          '会话或运行事实已变化，请重新核对退出范围。',
        );
      }
      unawaited(load());
    });
  }
  final WorkspaceRuntimeSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _changes;
  WorkspaceRuntimeStatus? value;
  WorkspaceFailure? readFailure, failure;
  WorkspaceQuitPreview? quitPreview;
  WorkspaceRuntimeReceipt? result;
  WorkspaceRuntimeChange? _command;
  WorkspaceQuitPreview? _expectedQuit;
  bool loading = false, busy = false, preparing = false, _closed = false;
  int _generation = 0, _previewGeneration = 0;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get available =>
      !frozen && !loading && !preparing && value != null && readFailure == null;
  bool get shutdownGate =>
      value != null && value!.phase != WorkspaceRuntimePhase.running;
  bool get canMaintain => available && !shutdownGate && value!.serviceAvailable;
  bool get canQuit => available && quitPreview != null && !value!.closed;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  WorkspaceFailure _readError(Object e, String message) =>
      e is WorkspaceFailure && e.code != 'unknown_outcome'
      ? e
      : WorkspaceFailure('unavailable', message);
  void begin() {
    if (_closed || !available) return;
    failure = null;
    result = null;
    _notify();
  }

  Future<void> load() async {
    if (_closed || frozen) return;
    final generation = ++_generation;
    loading = true;
    readFailure = null;
    _notify();
    try {
      final next = await source.status();
      if (!_closed && generation == _generation && !frozen) value = next;
    } catch (error) {
      if (!_closed && generation == _generation) {
        readFailure = _readError(error, '运行状态暂时无法读取，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> _release() async {
    final token = quitPreview?.token;
    quitPreview = null;
    if (token != null) {
      try {
        await source.releaseQuit(token);
      } catch (_) {
        /* No data or runtime capability is held by a count-only view. */
      }
    }
  }

  Future<void> prepareQuit() async {
    if (_closed || !available || value!.closed) return;
    final generation = ++_previewGeneration;
    preparing = true;
    failure = null;
    result = null;
    _notify();
    try {
      await _release();
      final next = await source.previewQuit();
      if (_closed || generation != _previewGeneration) {
        await source.releaseQuit(next.token);
        return;
      }
      if (!next.valid || next.version != value!.version) {
        await source.releaseQuit(next.token);
        throw const WorkspaceFailure('invalid_preview', '退出范围无法确认，请重新核对。');
      }
      quitPreview = next;
    } catch (error) {
      if (!_closed && generation == _previewGeneration) {
        failure = _readError(error, '暂时无法核对退出范围，尚未退出。');
      }
    } finally {
      if (!_closed && generation == _previewGeneration) {
        preparing = false;
        _notify();
      }
    }
  }

  Future<bool> closeQuit() async {
    if (_closed || frozen) return false;
    _previewGeneration++;
    preparing = false;
    await _release();
    _notify();
    return true;
  }

  WorkspaceRuntimeReceipt _check(WorkspaceRuntimeReceipt r) {
    if (!r.matches(_command!) ||
        _command!.action == WorkspaceRuntimeAction.quit &&
            (_expectedQuit == null ||
                r.quitScope == null ||
                jsonEncode(r.quitScope!.counts) !=
                    jsonEncode(_expectedQuit!.counts))) {
      throw const WorkspaceFailure('unknown_outcome', '回执与原运行操作不符，请继续核对原操作。');
    }
    return r;
  }

  Future<void> _finish(WorkspaceRuntimeReceipt r) async {
    result = r;
    _command = null;
    _expectedQuit = null;
    busy = false;
    failure = null;
    if (r.action == WorkspaceRuntimeAction.quit) await _release();
    _notify();
    await load();
  }

  Future<void> write(WorkspaceRuntimeAction action) async {
    if (_closed || !available) return;
    if (action == WorkspaceRuntimeAction.quit && !canQuit ||
        action == WorkspaceRuntimeAction.finishExit &&
            value!.phase != WorkspaceRuntimePhase.terminationFailed ||
        action != WorkspaceRuntimeAction.quit &&
            action != WorkspaceRuntimeAction.finishExit &&
            !canMaintain) {
      return;
    }
    _command = WorkspaceRuntimeChange(
      operationId: workspaceOperationId(),
      action: action,
      expectedVersion: value!.version,
      quitToken: action == WorkspaceRuntimeAction.quit
          ? quitPreview!.token
          : null,
    );
    _expectedQuit = action == WorkspaceRuntimeAction.quit ? quitPreview : null;
    busy = true;
    failure = null;
    result = null;
    _generation++;
    loading = false;
    _notify();
    try {
      final r = await source.change(_command!);
      if (!_closed) await _finish(_check(r));
    } catch (error) {
      if (!_closed) {
        busy = false;
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '运行操作结果未知，请核对原操作。');
        if (!uncertain) {
          _command = null;
          _expectedQuit = null;
          if ({'quit_changed', 'conflict'}.contains(failure!.code)) {
            await _release();
          }
        }
        _notify();
        if (!uncertain) await load();
      }
    }
  }

  Future<void> reconcile() async {
    if (_closed || !uncertain || busy || _command == null) return;
    busy = true;
    _notify();
    try {
      final r = await source.receipt(_command!.operationId);
      if (_closed) return;
      if (r == null) {
        _command = null;
        _expectedQuit = null;
        busy = false;
        failure = const WorkspaceFailure(
          'not_submitted',
          '原操作已确认未提交，需要明确重试才会再次执行。',
        );
        _notify();
        await load();
      } else {
        await _finish(_check(r));
      }
    } catch (_) {
      if (!_closed) {
        busy = false;
        failure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认原运行操作，请继续核对。',
        );
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _previewGeneration++;
    unawaited(_changes.cancel());
    unawaited(_release());
    super.dispose();
  }
}
