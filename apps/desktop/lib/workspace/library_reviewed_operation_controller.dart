import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

abstract class LibraryReviewedOperationController<P, C, R>
    extends ChangeNotifier {
  LibraryReviewedOperationController(this.source) {
    _changes = source.changes.listen((_) {
      if (_closed || frozen) return;
      _changeVersion++;
      needsReview = true;
      failure = const WorkspaceFailure('conflict', '目录或资料已变化，请重新读取并核对范围。');
      notifyListeners();
      unawaited(_verifyUnchangedPreview());
    });
  }
  final WorkspaceSource source;
  P? preview;
  Future<P> readPreview();
  C createCommand(P preview);
  Future<R> commit(C command);
  Future<R?> lookup(String operationId);
  String operationId(C command);
  bool matches(R receipt, C command);
  bool previewAllowsSave(P preview);

  /// Only adapters with an exact scope token opt in. Broad connection/audit
  /// refreshes must not force the user to approve an unchanged batch again.
  bool get canVerifyUnchangedPreview => false;
  bool previewsMatch(P previous, P current) => false;
  Future<void> _verifyUnchangedPreview() async {
    if (!canVerifyUnchangedPreview ||
        _closed ||
        frozen ||
        reading ||
        preview == null ||
        !needsReview ||
        receipt != null) {
      return;
    }
    final previous = preview as P,
        generation = _generation,
        changeVersion = _changeVersion;
    try {
      final currentCatalog = await source.loadCatalog();
      final current = await readPreview();
      if (_closed ||
          frozen ||
          reading ||
          generation != _generation ||
          changeVersion != _changeVersion ||
          !identical(preview, previous) ||
          !previewsMatch(previous, current)) {
        return;
      }
      catalog = currentCatalog;
      preview = current;
      needsReview = false;
      if (failure?.code == 'conflict') failure = null;
      notifyListeners();
    } on Object {
      // A failed verification is not an unchanged scope. Keep the original
      // preview and require the normal explicit review before any mutation.
    }
  }

  WorkspaceCatalog? catalog;
  WorkspaceFailure? failure;
  R? receipt;
  String? notice;
  bool busy = false, reading = false, needsReview = false, _closed = false;
  int _generation = 0, _changeVersion = 0;
  C? _command;
  late final StreamSubscription<WorkspaceRecordRef?> _changes;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get canSave =>
      receipt == null &&
      !frozen &&
      !reading &&
      !needsReview &&
      (preview != null && previewAllowsSave(preview as P)) &&
      failure?.code != 'conflict';
  Future<void> load() async {
    if (frozen || _closed) return;
    final generation = ++_generation, changeVersion = _changeVersion;
    reading = true;
    failure = null;
    notice = null;
    notifyListeners();
    try {
      final currentCatalog = await source.loadCatalog();
      if (_closed || generation != _generation) return;
      catalog = currentCatalog;
      final result = await readPreview();
      if (_closed || generation != _generation) return;
      catalog = currentCatalog;
      preview = result;
      needsReview = changeVersion != _changeVersion;
      if (needsReview) {
        failure = const WorkspaceFailure('conflict', '目录或资料已变化，请重新读取并核对范围。');
      }
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
        if (needsReview) unawaited(_verifyUnchangedPreview());
      }
    }
  }

  R _check(R result) {
    if (_command == null || !matches(result, _command as C)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与原操作不符，请继续核对结果。');
    }
    return result;
  }

  Future<void> save() async {
    if (!canSave || _closed) return;
    _command = createCommand(preview as P);
    busy = true;
    failure = null;
    notice = null;
    notifyListeners();
    try {
      final result = _check(await commit(_command as C));
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
      final result = await lookup(operationId(_command as C));
      if (result != null) {
        final checked = _check(result);
        if (!_closed) {
          receipt = checked;
          failure = null;
        }
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
