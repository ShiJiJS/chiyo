import 'dart:async';
import 'package:flutter/foundation.dart';

import 'local_library_sync.dart';
import 'workspace/workspace_sync.dart';

/// Lifecycle for the real local replica: one startup pass, explicit toolbar
/// refresh and bounded periodic polling. Folder selection never triggers it.
class LocalLibrarySyncController extends ChangeNotifier
    implements WorkspaceSync, WorkspaceSyncReview {
  LocalLibrarySyncController({
    required this.sync,
    required this.changed,
    this.interval = const Duration(minutes: 1),
    Timer Function(Duration, void Function(Timer))? schedule,
    DateTime Function()? clock,
  }) : _schedule = schedule ?? Timer.periodic,
       _clock = clock ?? DateTime.now {
    if (interval <= Duration.zero) throw ArgumentError.value(interval);
  }
  final LocalLibrarySync sync;
  final VoidCallback changed;
  final Duration interval;
  final Timer Function(Duration, void Function(Timer)) _schedule;
  final DateTime Function() _clock;
  Timer? _timer;
  Future<void>? _running;
  bool _closed = false, _paused = false;
  int _configurationGeneration = 0;
  @override
  bool enabled = false;
  @override
  bool get busy => _running != null;
  @override
  bool needsReview = false;
  @override
  DateTime? updatedAt;
  @override
  Object? failure;

  void _background() {
    unawaited(
      synchronize().catchError((Object _) {
        // Kept in state for the existing toolbar. No unhandled timer errors.
      }),
    );
  }

  Future<void> restore() async {
    final generation = ++_configurationGeneration;
    _paused = false;
    _timer?.cancel();
    _timer = null;
    try {
      final configuration = await sync.readConfiguration();
      if (_closed || _paused || generation != _configurationGeneration) return;
      enabled = configuration['enabled'] == true;
      if (!enabled) {
        failure = null;
        needsReview = false;
      }
      notifyListeners();
      if (enabled) {
        _timer = _schedule(interval, (_) => _background());
        _background();
      }
    } on Object catch (error) {
      if (!_closed && generation == _configurationGeneration) {
        failure = error;
        notifyListeners();
      }
    }
  }

  /// Settings wait for the current pass before changing connection or mode.
  Future<void> pause() async {
    _configurationGeneration++;
    _paused = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _running;
    } on Object {
      // A failed prior pass must not prevent correcting settings.
    }
  }

  @override
  Future<void> synchronize() {
    if (_closed || _paused || !enabled) return Future.value();
    if (_running != null) return _running!;
    final completer = Completer<void>();
    _running = completer.future;
    notifyListeners();
    unawaited(() async {
      try {
        final result = await sync.synchronize(
          changed: () {
            if (!_closed) changed();
          },
        );
        if (!_closed) {
          failure = null;
          needsReview = result.needsReview;
          updatedAt = _clock();
        }
        completer.complete();
      } catch (error, stack) {
        if (!_closed) failure = error;
        completer.completeError(error, stack);
      } finally {
        _running = null;
        if (!_closed) notifyListeners();
      }
    }());
    return completer.future;
  }

  @override
  Future<List<Map<String, Object?>>> reviewConflicts() async {
    await _running;
    return sync.reviewConflicts();
  }

  @override
  Future<void> resolveConflict(
    Map<String, Object?> reviewed,
    bool useIncoming,
    String operationId,
  ) async {
    await pause();
    try {
      await sync.resolveConflict(reviewed, useIncoming, operationId);
      changed();
    } finally {
      await restore();
    }
    await synchronize();
  }

  @override
  void dispose() {
    _configurationGeneration++;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
