import 'package:flutter/foundation.dart';
import '../desktop_runtime.dart';
import '../desktop_scroll.dart';
import 'workspace_desktop.dart';
import 'workspace_source.dart';

/// Uses the already running native lifecycle; never initializes another method
/// channel handler or bypasses the service's save/stop/terminate sequence.
class RuntimeWorkspaceDesktop implements WorkspaceDesktop {
  RuntimeWorkspaceDesktop(this.runtime)
    : scrollbarStyle = ValueNotifier(runtime.availability.scrollbarStyle),
      _navigationRevision = runtime.navigationRevision {
    runtime.addListener(_changed);
    _pending = _destination(runtime.lastNavigationEvent);
  }
  final DesktopRuntime runtime;
  @override
  final ValueNotifier<DesktopScrollbarStyle> scrollbarStyle;
  int _navigationRevision;
  bool _enabled = true, _disposed = false;
  WorkspacePage? _pending;
  void Function(WorkspacePage)? _navigate;
  static WorkspacePage? _destination(DesktopEvent? event) => switch (event) {
    DesktopEvent.openApprovals => WorkspacePage.approvals,
    DesktopEvent.openSettings => WorkspacePage.settings,
    DesktopEvent.searchApprovals => WorkspacePage.library,
    _ => null,
  };
  @override
  void Function(WorkspacePage)? get onNavigate => _navigate;
  @override
  set onNavigate(void Function(WorkspacePage)? callback) {
    _navigate = callback;
    _deliver();
  }

  void _deliver() {
    if (_disposed ||
        !_enabled ||
        _navigate == null ||
        _pending == null ||
        runtime.quitting ||
        runtime.stopped) {
      return;
    }
    final page = _pending!;
    _pending = null;
    _navigate!(page);
  }

  void _changed() {
    if (_disposed) return;
    scrollbarStyle.value = runtime.availability.scrollbarStyle;
    if (_navigationRevision != runtime.navigationRevision) {
      _navigationRevision = runtime.navigationRevision;
      // Native commands received during an editor/modal are rejected. They
      // must not turn into a surprising page switch when the editor closes.
      _pending = _enabled ? _destination(runtime.lastNavigationEvent) : null;
    }
    _deliver();
  }

  @override
  Future<void> setNavigationEnabled(bool enabled) async {
    if (_disposed) return;
    _enabled = enabled;
    if (!enabled) _pending = null;
    if (runtime.platform case final DesktopNavigationPlatform platform) {
      try {
        await platform
            .setNavigationEnabled(
              enabled && !runtime.quitting && !runtime.stopped,
            )
            .timeout(const Duration(seconds: 2));
      } on Object {
        // Retain the Dart navigation gate when an older/native runner cannot
        // update its menu. Native events still pass through _deliver.
      }
    }
    _deliver();
  }

  @override
  Future<void> quit() => runtime.quit();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    runtime.removeListener(_changed);
    _navigate = null;
    _pending = null;
    scrollbarStyle.dispose();
  }
}
