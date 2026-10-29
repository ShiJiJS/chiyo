import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class HostImportController extends ChangeNotifier {
  HostImportController(this.source);
  final WorkspaceHostSource source;
  WorkspaceHostFile? file;
  WorkspaceHostImportPreview? preview;
  WorkspaceFailure? failure;
  WorkspaceHostImportReceipt? result;
  WorkspaceHostImportChange? _command;
  bool busy = false, choosing = false, _closed = false;
  int _generation = 0;
  bool get uncertain => _command != null && failure?.code == 'unknown_outcome';
  bool get frozen => busy || choosing || uncertain;
  bool get canSubmit =>
      !frozen && preview != null && failure?.code != 'conflict';
  void _notify() {
    if (!_closed) notifyListeners();
  }

  WorkspaceFailure _readFailure(Object e) =>
      e is WorkspaceFailure && e.code != 'unknown_outcome'
      ? e
      : const WorkspaceFailure('unavailable', '暂时无法读取所选文件，请重试。');

  Future<bool> pick(WorkspaceHostFilePicker picker) async {
    if (_closed || frozen) return false;
    choosing = true;
    failure = null;
    _notify();
    try {
      final next = await picker();
      if (_closed) {
        if (next != null) await source.releaseImport(next.selectionId);
        return false;
      }
      if (next == null) return false;
      if (file case final old?) await source.releaseImport(old.selectionId);
      if (_closed) {
        await source.releaseImport(next.selectionId);
        return false;
      }
      file = next;
      preview = null;
      result = null;
    } catch (e) {
      if (!_closed) failure = _readFailure(e);
      return true;
    } finally {
      choosing = false;
      _notify();
    }
    await review();
    return true;
  }

  Future<void> review() async {
    if (_closed || frozen || file == null) return;
    final generation = ++_generation;
    busy = true;
    failure = null;
    preview = null;
    result = null;
    _command = null;
    _notify();
    try {
      final p = await source.previewImport(file!.selectionId);
      if (!_closed && generation == _generation) {
        if (p.file.selectionId != file!.selectionId ||
            p.file.name != file!.name ||
            p.file.byteLength != file!.byteLength) {
          throw const WorkspaceFailure('conflict', '预览与本次文件选择不符，请重新选择。');
        }
        preview = p;
      }
    } catch (e) {
      if (!_closed && generation == _generation) failure = _readFailure(e);
    } finally {
      if (!_closed && generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  WorkspaceHostImportReceipt _check(WorkspaceHostImportReceipt receipt) {
    if (_command == null || !receipt.matches(_command!)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次文件导入不符，请继续核对原操作。');
    }
    return receipt;
  }

  Future<void> submit() async {
    if (_closed || !canSubmit) return;
    _command = WorkspaceHostImportChange(workspaceOperationId(), preview!);
    result = null;
    busy = true;
    failure = null;
    _notify();
    try {
      final receipt = _check(await source.importFile(_command!));
      if (!_closed) result = receipt;
    } catch (e) {
      if (!_closed) {
        failure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unknown_outcome', '导入结果未知，请先核对本次操作。');
        if (!uncertain) _command = null;
      }
    } finally {
      if (!_closed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> reconcile() async {
    if (_closed || busy || !uncertain) return;
    busy = true;
    _notify();
    try {
      final receipt = await source.importReceipt(_command!.operationId);
      final checked = receipt == null ? null : _check(receipt);
      if (!_closed) {
        result = checked;
        _command = null;
        failure = null;
        // A confirmed absence requires a fresh version review before retry.
        if (checked == null) preview = null;
      }
    } catch (_) {
      if (!_closed) {
        failure = const WorkspaceFailure('unknown_outcome', '仍无法确认导入结果，请稍后核对。');
      }
    } finally {
      if (!_closed) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    final selected = file;
    if (selected != null) source.releaseImport(selected.selectionId);
    super.dispose();
  }
}
