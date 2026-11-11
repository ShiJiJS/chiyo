import 'dart:async';
import 'package:flutter/foundation.dart';
import '../desktop_runtime.dart';
import '../desktop_scroll.dart';
import '../mac_pending_menu.dart';
import 'workspace_desktop.dart';
import 'workspace_source.dart';

/// Uses the already running native lifecycle; never initializes another method
/// channel handler or bypasses the service's save/stop/terminate sequence.
class RuntimeWorkspaceDesktop
    implements
        WorkspaceDesktop,
        WorkspaceRequestNavigation,
        WorkspaceMenuNavigation {
  RuntimeWorkspaceDesktop(this.runtime)
    : scrollbarStyle = ValueNotifier(runtime.availability.scrollbarStyle),
      _navigationRevision = runtime.navigationRevision {
    runtime.addListener(_changed);
    _pending = _destination(runtime.lastNavigationEvent);
    _pendingRequestId = _requestDestination();
    if (runtime.platform case final DesktopPendingMenuPlatform native
        when native.supportsPendingMenu) {
      final menu = _menu = MacPendingMenu(
        publish: native.updatePendingMenu,
        canAct: () =>
            !_disposed && _enabled && !runtime.quitting && !runtime.stopped,
        theme: () => _theme,
        open: (page, id) async {
          await runtime.showWorkingWindow();
          if (_disposed || !_enabled || runtime.quitting || runtime.stopped) {
            return;
          }
          if (id == null) {
            _navigate?.call(page);
          } else {
            onOpenMenuDetail?.call(page, id);
          }
        },
      );
      native.setPendingMenuHandler(menu.handle);
    }
  }

  MacPendingMenu? _menu;
  WorkspaceSource? _source;
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  WorkspaceTheme _theme = WorkspaceTheme.light;
  @override
  void Function(WorkspacePage, String)? onOpenMenuDetail;

  void bindSource(WorkspaceSource source) {
    _source = source;
    _menu?.bind(source, location: '本地模式');
    unawaited(_changes?.cancel());
    _changes = source.changes.listen((_) => unawaited(_refreshMenu(source)));
    unawaited(_refreshMenu(source));
  }

  Future<void> _refreshMenu(WorkspaceSource source) async {
    if (_menu == null || _disposed || runtime.quitting || runtime.stopped) {
      return;
    }
    try {
      final preferences = await source.settings.read();
      if (!identical(source, _source) || _disposed) return;
      _theme = preferences.theme;
      await _menu?.refresh();
    } on Object {
      // The normal workspace exposes its original read failure.
    }
  }

  final DesktopRuntime runtime;
  @override
  final ValueNotifier<DesktopScrollbarStyle> scrollbarStyle;
  int _navigationRevision;
  bool _enabled = true, _disposed = false;
  WorkspacePage? _pending;
  String? _pendingRequestId;
  @override
  void Function(String)? onOpenRequest;
  String? _requestDestination() =>
      runtime.lastNavigationEvent == DesktopEvent.openApprovals
      ? runtime.openRequestId
      : null;
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
    final requestId = _pendingRequestId;
    _pending = null;
    _pendingRequestId = null;
    if (page == WorkspacePage.approvals &&
        requestId != null &&
        onOpenRequest != null) {
      onOpenRequest!(requestId);
    } else {
      _navigate!(page);
    }
  }

  void _changed() {
    if (_disposed) return;
    scrollbarStyle.value = runtime.availability.scrollbarStyle;
    if (runtime.quitting || runtime.stopped) _menu?.dispose();
    if (_navigationRevision != runtime.navigationRevision) {
      _navigationRevision = runtime.navigationRevision;
      // Native commands received during an editor/modal are rejected. They
      // must not turn into a surprising page switch when the editor closes.
      _pending = _enabled ? _destination(runtime.lastNavigationEvent) : null;
      _pendingRequestId = _enabled ? _requestDestination() : null;
    }
    _deliver();
  }

  @override
  Future<void> setNavigationEnabled(bool enabled) async {
    if (_disposed) return;
    if (_enabled != enabled) runtime.discardPendingNavigation();
    _enabled = enabled;
    if (!enabled) {
      _pending = null;
      _pendingRequestId = null;
    }
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
    onOpenRequest = null;
    onOpenMenuDetail = null;
    _menu?.dispose();
    unawaited(_changes?.cancel());
    if (runtime.platform case final DesktopPendingMenuPlatform native) {
      native.setPendingMenuHandler(null);
    }
    _pending = null;
    _pendingRequestId = null;
    scrollbarStyle.dispose();
  }
}
