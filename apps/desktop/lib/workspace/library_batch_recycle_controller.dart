import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class LibraryBatchRecycleController extends ChangeNotifier {
  LibraryBatchRecycleController(this.source, {this.selection, this.batchId}) {
    _changes = source.changes.listen((_) {
      if (_closed || frozen || reading) return;
      needsReview = true;
      failure = const WorkspaceFailure('conflict', '目录或资料已变化，请重新读取并核对范围。');
      notifyListeners();
    });
  }
  final WorkspaceSource source;
  final WorkspaceLibrarySelection? selection;
  final String? batchId;
  WorkspaceLibraryRecycle get port => source as WorkspaceLibraryRecycle;
  bool get restoring => batchId != null;
  WorkspaceLibraryRestoreOptions options = WorkspaceLibraryRestoreOptions();
  WorkspaceLibraryRecyclePreview? preview;
  WorkspaceCatalog? catalog;
  WorkspaceFailure? failure;
  WorkspaceLibraryRecycleReceipt? receipt;
  String? notice;
  bool busy = false, reading = false, needsReview = false, _closed = false;
  int _generation = 0;
  WorkspaceLibraryRecycleCommand? _command;
  late final StreamSubscription<WorkspaceRecordRef?> _changes;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get canSave =>
      !frozen &&
      !reading &&
      !needsReview &&
      preview?.canSave == true &&
      failure?.code != 'conflict';
  void rename(String id, String name) {
    if (frozen || reading) return;
    options = WorkspaceLibraryRestoreOptions(
      names: {...options.names, id: name},
      parents: options.parents,
    );
    needsReview = true;
    failure = null;
    notice = null;
    notifyListeners();
  }

  Future<void> moveRoot(String id, String? parent) async {
    if (frozen || reading) return;
    options = WorkspaceLibraryRestoreOptions(
      names: options.names,
      parents: {...options.parents, id: parent},
    );
    needsReview = true;
    await load();
  }

  Future<void> load() async {
    if (frozen || _closed) return;
    final generation = ++_generation;
    reading = true;
    failure = null;
    notice = null;
    notifyListeners();
    try {
      final currentCatalog = await source.loadCatalog();
      final result = restoring
          ? await port.previewLibraryRecycleRestore(batchId!, options)
          : await port.previewLibraryRecycle(selection!);
      if (_closed || generation != _generation) return;
      catalog = currentCatalog;
      preview = result;
      needsReview = false;
    } catch (e) {
      if (!_closed && generation == _generation) {
        preview = null;
        failure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unavailable', '暂时无法读取范围，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        reading = false;
        notifyListeners();
      }
    }
  }

  WorkspaceLibraryRecycleReceipt _check(WorkspaceLibraryRecycleReceipt result) {
    if (_command == null || !result.matches(_command!)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与原操作不符，请继续核对结果。');
    }
    return result;
  }

  Future<void> save() async {
    if (!canSave || _closed) return;
    _command = WorkspaceLibraryRecycleCommand(
      operationId: workspaceOperationId(),
      reviewToken: preview!.token,
      selection: selection,
      batchId: batchId,
      options: options,
    );
    busy = true;
    failure = null;
    notice = null;
    notifyListeners();
    try {
      final result = _check(await port.changeLibraryRecycle(_command!));
      if (!_closed) receipt = result;
    } catch (e) {
      if (!_closed) {
        failure = e is WorkspaceFailure
            ? e
            : const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对原操作。');
        if (!uncertain) _command = null;
      }
    } finally {
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> reconcile() async {
    if (!uncertain || busy || _closed || _command == null) return;
    busy = true;
    notifyListeners();
    var absent = false;
    try {
      final result = await port.libraryRecycleOperationReceipt(
        _command!.operationId,
      );
      if (result != null) {
        final checked = _check(result);
        if (!_closed) receipt = checked;
      } else {
        absent = true;
        if (!_closed) {
          failure = null;
          _command = null;
        }
      }
    } catch (_) {
      if (!_closed) {
        failure = const WorkspaceFailure('unknown_outcome', '仍无法确认原操作，请稍后核对。');
      }
    } finally {
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
    }
    if (absent && !_closed) {
      await load();
      if (!_closed) {
        notice = '已确认尚未提交，请核对当前范围后再保存。';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    unawaited(_changes.cancel());
    super.dispose();
  }
}
