import 'dart:async';
import 'package:info_core/macos_desktop_control.dart';
import 'package:flutter/foundation.dart';
import 'desktop_runtime.dart';
import 'desktop_scroll.dart';
import 'workspace/remote_workspace_source.dart';
import 'workspace/workspace_desktop.dart';
import 'workspace/workspace_source.dart';

/// Owns this App's native window and connections, never the independent server,
/// Agent sessions, credential executor, or another device's files/processes.
class OnlineDesktopRuntime extends ChangeNotifier
    implements WorkspaceDesktop, WorkspaceRequestNavigation {
  OnlineDesktopRuntime({
    required this.platform,
    required this.beforeExit,
    required this.onResume,
    this.openAppControl,
  });
  final DesktopPlatform platform;
  final Future<void> Function() beforeExit, onResume;
  final Future<MacDesktopControlHost> Function(
    String Function() state,
    Future<void> Function() quit,
  )?
  openAppControl;
  MacDesktopControlHost? _appControl;
  Future<void> Function()? _commitControlExit;
  bool _controlStarted = false;
  String get _controlState => shutdownFailed
      ? 'shutdown_failed'
      : quitting
      ? 'exiting'
      : _controlStarted
      ? 'running'
      : 'starting';
  DesktopAvailability availability = DesktopAvailability.unavailable;
  @override
  final ValueNotifier<DesktopScrollbarStyle> scrollbarStyle = ValueNotifier(
    DesktopScrollbarStyle.legacy,
  );
  RemoteWorkspaceSource? _source;
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  Future<void>? _starting, _refreshing, _quitting;
  bool _disposed = false, _enabled = true, _baseline = false;
  bool windowHidden = false, quitting = false, closed = false;
  bool shutdownFailed = false, notificationReadFailed = false;
  bool resourcesClosed = false;
  bool get navigationEnabled => _enabled;
  int _binding = 0, _navigationIntent = 0;
  final _seen = <String>{};
  WorkspacePreferences? preferences;
  WorkspacePage? _pendingPage;
  String? _pendingRequest;
  void Function(WorkspacePage)? _navigate;
  void Function(String)? _openRequest;
  @override
  void Function(WorkspacePage)? get onNavigate => _navigate;
  @override
  set onNavigate(void Function(WorkspacePage)? value) {
    _navigate = value;
    _deliver();
  }

  @override
  void Function(String)? get onOpenRequest => _openRequest;
  @override
  set onOpenRequest(void Function(String)? value) {
    _openRequest = value;
    _deliver();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _availability(DesktopAvailability next) {
    if (_disposed) return;
    availability = next;
    scrollbarStyle.value = next.scrollbarStyle;
    _changed();
  }

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    try {
      final value = await platform
          .initialize(handleEvent)
          .timeout(const Duration(seconds: 5));
      if (!_disposed) _availability(value);
    } on Object {
      if (!_disposed) _availability(DesktopAvailability.unavailable);
    }
    if (!_disposed && openAppControl != null) {
      try {
        final control = await openAppControl!(
          () => _controlState,
          () => handleEvent(DesktopEvent.quit),
        );
        if (_disposed) {
          await control.close();
          return;
        }
        _appControl = control;
        if (platform case final NativeDesktopPlatform native) {
          native.commitAppControlExit = _commitControlExit = control.commitExit;
        }
      } on Object {
        // Control is optional. Never overwrite an existing private registry or
        // stop connection/normal menu quit because another instance owns it.
      }
    }
    _controlStarted = true;
  }

  Future<void> bind(RemoteWorkspaceSource? source) async {
    final binding = ++_binding;
    _navigationIntent++;
    _pendingPage = null;
    _pendingRequest = null;
    await _changes?.cancel();
    if (_disposed || binding != _binding) return;
    _source = source;
    preferences = null;
    _baseline = false;
    _seen.clear();
    if (_disposed || binding != _binding || source == null) return;
    _changes = source.changes.listen((_) => unawaited(refresh()));
    // Wait for any old binding's read, without treating an observation timeout
    // as an absent request or starting a duplicate refresh.
    await _refreshing;
    if (!_disposed && binding == _binding) await refresh();
  }

  Future<void> release(RemoteWorkspaceSource source) async {
    if (identical(_source, source)) await bind(null);
    await _refreshing;
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    final source = _source, binding = _binding;
    if (_disposed || source == null || quitting) return;
    try {
      await start();
      if (_disposed || binding != _binding || quitting) return;
      final saved = await source.settings.read();
      if (_disposed || binding != _binding || quitting) return;
      final pending = <WorkspaceApprovalSummary>[];
      var offset = 0;
      while (true) {
        if (_disposed || binding != _binding || quitting) return;
        final page = await source.approvals.query(
          WorkspaceApprovalQuery(
            filter: WorkspaceApprovalFilter.pending,
            offset: offset,
            limit: 100,
          ),
        );
        pending.addAll(page.items);
        offset += page.items.length;
        if (offset >= page.total) break;
        if (page.items.isEmpty || offset > 100000) {
          throw const FormatException();
        }
      }
      if (_disposed || binding != _binding || quitting) return;
      preferences = saved;
      notificationReadFailed = false;
      final baseline = _baseline;
      _baseline = true;
      for (final r in pending) {
        if (_disposed || binding != _binding || quitting) return;
        final fresh = _seen.add(r.id);
        if (!baseline ||
            !fresh ||
            !saved.notifications ||
            availability.notifications != NotificationAvailability.enabled) {
          continue;
        }
        try {
          if (await platform.notifyNewRequest(r.id)) continue;
        } on Object {
          /* A failed reminder cannot discard the real request. */
        }
        await _refreshAvailability(failedDelivery: true);
      }
      _changed();
    } on Object {
      if (!_disposed && binding == _binding && !quitting) {
        notificationReadFailed = true;
        _changed();
      }
    }
  }

  Future<void> _refreshAvailability({bool failedDelivery = false}) async {
    DesktopAvailability value;
    try {
      value = await platform.readAvailability();
    } on Object {
      value = DesktopAvailability.unavailable;
    }
    if (failedDelivery &&
        value.notifications == NotificationAvailability.enabled) {
      value = DesktopAvailability(
        tray: value.tray,
        notifications: NotificationAvailability.unavailable,
        scrollbarStyle: value.scrollbarStyle,
      );
    }
    if (!_disposed && !quitting) _availability(value);
  }

  /// Called only after the user's explicit off-to-on setting change. It is
  /// never called by startup, polling, receipt reconciliation or reconnection.
  Future<void> enableNotifications() async {
    if (_disposed ||
        quitting ||
        availability.notifications != NotificationAvailability.notEnabled) {
      return;
    }
    try {
      _availability(await platform.requestNotificationPermission());
    } on Object {
      await _refreshAvailability();
    }
  }

  Future<bool> hideWindow() async {
    if (_disposed ||
        quitting ||
        preferences?.background != true ||
        !availability.tray) {
      return false;
    }
    try {
      final hidden = await platform.hideWindow();
      if (_disposed || quitting) return false;
      windowHidden = hidden;
      if (!hidden) {
        _availability(
          DesktopAvailability(
            tray: false,
            notifications: availability.notifications,
            scrollbarStyle: availability.scrollbarStyle,
          ),
        );
      }
      _changed();
      return hidden;
    } on Object {
      return false;
    }
  }

  Future<void> showWindow() async {
    await platform.showWindow();
    if (_disposed) return;
    windowHidden = false;
    _changed();
  }

  void _deliver() {
    if (_disposed ||
        quitting ||
        !_enabled ||
        _source == null ||
        _navigate == null ||
        _pendingPage == null) {
      return;
    }
    final page = _pendingPage!, request = _pendingRequest;
    _pendingPage = null;
    _pendingRequest = null;
    if (page == WorkspacePage.approvals &&
        request != null &&
        _openRequest != null) {
      _openRequest!(request);
    } else {
      _navigate!(page);
    }
  }

  @override
  Future<void> setNavigationEnabled(bool enabled) async {
    if (_disposed) return;
    if (_enabled != enabled) _navigationIntent++;
    _enabled = enabled;
    if (!enabled) {
      _pendingPage = null;
      _pendingRequest = null;
    }
    if (platform case final DesktopNavigationPlatform navigation) {
      try {
        await navigation
            .setNavigationEnabled(enabled && !quitting)
            .timeout(const Duration(seconds: 2));
      } on Object {
        /* The Dart gate remains authoritative for callbacks. */
      }
    }
    _deliver();
  }

  Future<void> handleEvent(DesktopEvent event) async {
    if (_disposed) return;
    if (event == DesktopEvent.quit) {
      if (!_enabled && !shutdownFailed) throw StateError('navigation_locked');
      await quit();
      if (shutdownFailed) throw StateError('app_exit_failed');
      return;
    }
    if (quitting) {
      if (shutdownFailed &&
          const {
            DesktopEvent.openApprovals,
            DesktopEvent.openSettings,
            DesktopEvent.searchApprovals,
          }.contains(event)) {
        await showWindow();
      }
      return;
    }
    switch (event) {
      case DesktopEvent.closeWindow:
        if (preferences?.background == false) {
          if (_enabled) await quit();
        } else {
          await hideWindow();
        }
      case DesktopEvent.openApprovals:
      case DesktopEvent.openSettings:
      case DesktopEvent.searchApprovals:
        if (!_enabled) return;
        final intent = ++_navigationIntent, binding = _binding;
        final request = platform.openedRequestId;
        await showWindow();
        if (_disposed ||
            quitting ||
            !_enabled ||
            intent != _navigationIntent ||
            binding != _binding) {
          return;
        }
        _pendingPage = switch (event) {
          DesktopEvent.openApprovals => WorkspacePage.approvals,
          DesktopEvent.openSettings => WorkspacePage.settings,
          _ => WorkspacePage.library,
        };
        _pendingRequest = event == DesktopEvent.openApprovals ? request : null;
        _deliver();
      case DesktopEvent.availabilityChanged:
        await _refreshAvailability();
        if (!availability.tray && windowHidden) await showWindow();
      case DesktopEvent.resumed:
        await _refreshAvailability();
        await onResume();
        await refresh();
      case DesktopEvent.quit:
        break;
    }
  }

  @override
  Future<void> quit() {
    if (_disposed || closed) return Future.value();
    return _quitting ??= _quit().whenComplete(() => _quitting = null);
  }

  Future<void> _quit() async {
    quitting = true;
    shutdownFailed = false;
    _navigationIntent++;
    _pendingPage = null;
    _pendingRequest = null;
    _changed();
    try {
      await start();
      await _refreshing;
      if (!resourcesClosed) {
        await beforeExit();
        resourcesClosed = true;
      }
      await platform.terminate();
      closed = true;
      windowHidden = false;
    } on Object {
      // Retain the same lifetime and already closed resource facts for retry.
      // No server stop, session end, process signal or command replay exists.
      shutdownFailed = true;
      try {
        await showWindow();
      } on Object {
        /* Retain the actual hidden state. */
      }
    }
    _changed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _binding++;
    _navigationIntent++;
    unawaited(_changes?.cancel());
    _navigate = null;
    _openRequest = null;
    if (platform case final NativeDesktopPlatform native) {
      if (identical(native.commitAppControlExit, _commitControlExit)) {
        native.commitAppControlExit = null;
      }
    }
    unawaited(_appControl?.close());
    scrollbarStyle.dispose();
    super.dispose();
  }
}
