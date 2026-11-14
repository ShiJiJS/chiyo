import 'dart:async';

/// A background change never supersedes a read that is still producing its
/// first result. Bursts request one follow-up pass. Explicit navigation starts
/// immediately; the controller's generation checks discard its older results.
class WorkspaceRefresh {
  Future<void>? _active;
  Future<void> Function()? _pending;
  bool _closed = false;

  Future<void> run(Future<void> Function() read, {bool background = false}) {
    if (_closed) return Future.value();
    if (background && _active != null) {
      _pending = read;
      return _active!;
    }
    final done = Completer<void>();
    final task = done.future;
    _active = task;
    _pending = null;
    unawaited(() async {
      try {
        var next = read;
        while (true) {
          await next();
          if (_closed || !identical(_active, task) || _pending == null) break;
          next = _pending!;
          _pending = null;
        }
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        if (identical(_active, task)) _active = null;
      }
    }());
    return task;
  }

  void dispose() {
    _closed = true;
    _pending = null;
  }
}
