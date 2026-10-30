import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'desktop_scroll.dart';

enum DesktopEvent {
  closeWindow,
  openApprovals,
  openSettings,
  searchApprovals,
  quit,
  availabilityChanged,
  resumed,
}

enum NotificationAvailability { enabled, notEnabled, denied, unavailable }

class DesktopAvailability {
  const DesktopAvailability({
    required this.tray,
    required this.notifications,
    this.scrollbarStyle = DesktopScrollbarStyle.legacy,
  });
  final bool tray;
  final NotificationAvailability notifications;
  final DesktopScrollbarStyle scrollbarStyle;
  static const unavailable = DesktopAvailability(
    tray: false,
    notifications: NotificationAvailability.unavailable,
  );
}

/// Owner-process-only native boundary. Only an opaque request ID crosses this
/// boundary for routing; no submitted text or authorization material is sent.
abstract interface class DesktopPlatform {
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  );
  Future<bool> hideWindow();
  Future<void> showWindow();
  String? get openedRequestId;
  Future<bool> notifyNewRequest(String requestId);
  Future<bool> notifyTest();
  Future<DesktopAvailability> readAvailability();
  Future<DesktopAvailability> requestNotificationPermission();
  Future<void> terminate();
}

/// Optional native navigation controls. Lifetime interception is initialized
/// before opening the library, so it does not imply the workspace is ready.
abstract interface class DesktopNavigationPlatform {
  Future<void> setNavigationEnabled(bool enabled);
}

class NativeDesktopPlatform
    implements DesktopPlatform, DesktopNavigationPlatform {
  Future<void> Function()? commitAppControlExit;
  @override
  String? openedRequestId;
  static const _channel = MethodChannel('agent_info_manage/desktop');
  DesktopAvailability _decode(Object? raw) {
    if (raw is! Map) return DesktopAvailability.unavailable;
    return DesktopAvailability(
      tray: raw['tray'] == true,
      scrollbarStyle: raw['scrollbarStyle'] == 'overlay'
          ? DesktopScrollbarStyle.overlay
          : DesktopScrollbarStyle.legacy,
      notifications: switch (raw['notifications']) {
        'enabled' => NotificationAvailability.enabled,
        'not_enabled' => NotificationAvailability.notEnabled,
        'denied' => NotificationAvailability.denied,
        _ => NotificationAvailability.unavailable,
      },
    );
  }

  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  ) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        openedRequestId = call.arguments is String
            ? call.arguments as String
            : null;
      }
      final event = switch (call.method) {
        'close' => DesktopEvent.closeWindow,
        'open' => DesktopEvent.openApprovals,
        'openSettings' => DesktopEvent.openSettings,
        'searchApprovals' => DesktopEvent.searchApprovals,
        'quit' => DesktopEvent.quit,
        'availability' => DesktopEvent.availabilityChanged,
        'resume' => DesktopEvent.resumed,
        _ => null,
      };
      if (event != null) await onEvent(event);
    });
    return _decode(await _channel.invokeMethod<Object?>('initialize'));
  }

  @override
  Future<bool> hideWindow() async =>
      await _channel.invokeMethod<bool>('hide') ?? false;
  @override
  Future<void> showWindow() => _channel.invokeMethod<void>('show');
  @override
  Future<bool> notifyNewRequest(String requestId) async =>
      await _channel
          .invokeMethod<bool>('notify', requestId)
          .timeout(const Duration(seconds: 45), onTimeout: () => false) ??
      false;
  @override
  Future<bool> notifyTest() async =>
      await _channel
          .invokeMethod<bool>('testNotify')
          .timeout(const Duration(seconds: 45), onTimeout: () => false) ??
      false;
  @override
  Future<DesktopAvailability> requestNotificationPermission() async =>
      _decode(await _channel.invokeMethod<Object?>('enableNotifications'));
  @override
  Future<DesktopAvailability> readAvailability() async =>
      _decode(await _channel.invokeMethod<Object?>('availability'));
  @override
  Future<void> terminate() async {
    try {
      await commitAppControlExit?.call().timeout(const Duration(seconds: 2));
    } on Object {
      // An unavailable control receipt cannot prevent the owner from quitting.
      // CLI must then leave the process exit unconfirmed instead of inventing it.
    }
    await _channel.invokeMethod<void>('terminate');
  }

  @override
  Future<void> setNavigationEnabled(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    await _channel.invokeMethod<void>('setNavigationEnabled', enabled);
  }
}

/// Owns background lifetime independently of the currently visible Flutter tab.
/// Native close means hide; only explicit full quit destroys authorization.
class DesktopRuntime extends ChangeNotifier {
  DesktopRuntime({
    required this.service,
    required this.platform,
    required this.closeServer,
    required this.closeRepository,
  });
  final InformationService service;
  final DesktopPlatform platform;
  final Future<void> Function() closeServer;
  final Future<void> Function() closeRepository;
  DesktopAvailability availability = DesktopAvailability.unavailable;
  int openApprovalsRevision = 0;
  int openSettingsRevision = 0;
  int searchApprovalsRevision = 0;
  String? openRequestId;
  bool quitting = false;
  bool shutdownFailed = false;
  StreamSubscription<String>? _requests;
  Timer? _maintenanceTimer;
  Future<void> _maintenance = Future.value();
  bool recycleCleanupFailed = false;
  bool revisionCleanupFailed = false;
  bool attachmentCleanupFailed = false;
  bool informationDeliveryCleanupFailed = false;
  bool credentialCleanupFailed = false;
  bool runtimeMaterialCleanupFailed = false;
  int runtimeMaterialChecks = 0;
  Future<void>? _quit;
  Future<void>? _stop;
  Future<void>? _resuming;
  bool _stopped = false;
  // Native termination may fail after the repository is already closed. The
  // launcher must keep repository-backed widgets unmounted in that state.
  bool get stopped => _stopped;
  final _ready = Completer<void>();

  Future<void> start() async {
    // Subscribe before any asynchronous maintenance: a request arriving during
    // cleanup must still be delivered once native initialization is ready.
    _requests = service.owner.requestSubmitted.listen((id) {
      unawaited(_notify(id));
    });
    await _maintain();
    _maintenanceTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_maintain());
    });
    try {
      availability = await platform.initialize(handleEvent);
    } on Object {
      availability = DesktopAvailability.unavailable;
    }
    if (!_ready.isCompleted) _ready.complete();
    if (!quitting && !_stopped) await _setNavigationEnabled(true);
    notifyListeners();
  }

  Future<void> _setNavigationEnabled(bool enabled) async {
    if (platform case final DesktopNavigationPlatform navigation) {
      try {
        await navigation
            .setNavigationEnabled(enabled)
            .timeout(const Duration(seconds: 2));
      } on Object {
        // Older runners and native startup failures retain the in-app entry.
      }
    }
  }

  Future<void> _maintain() => _maintenance = _maintenance.then((_) async {
    if (quitting) return;
    try {
      await service.owner.purgeRecycle();
      recycleCleanupFailed = false;
    } catch (_) {
      recycleCleanupFailed = true;
    }
    try {
      await service.owner.purgeRevisions();
      revisionCleanupFailed = false;
    } catch (_) {
      revisionCleanupFailed = true;
    }
    try {
      await service.owner.purgeExpiredCredentialMaterial();
      credentialCleanupFailed = false;
    } catch (_) {
      credentialCleanupFailed = true;
    }
    await _checkInformationFiles();
    await reconcileRuntimeMaterialCleanup();
    try {
      await service.owner.pruneCredentialUseHistory();
    } catch (_) {
      credentialCleanupFailed = true;
    }
    notifyListeners();
  });
  Future<void> reconcileInformationFiles() =>
      _maintenance = _maintenance.then((_) async {
        if (quitting) return;
        await _checkInformationFiles();
      });

  Future<void> _checkInformationFiles() async {
    try {
      if (service.owner.informationFileDeliveries.any(
        (record) => record.holdsCopy,
      )) {
        await service.owner.reconcileInformationFileDeliveries();
      }
      informationDeliveryCleanupFailed = service.owner.informationFileDeliveries
          .any((record) => record.runtime && record.state == 'cleanup_pending');
    } catch (_) {
      informationDeliveryCleanupFailed = true;
    }
    try {
      await service.owner.purgeInformationAttachments();
      attachmentCleanupFailed = false;
    } catch (_) {
      attachmentCleanupFailed = true;
    }
    notifyListeners();
  }

  Future<void> reconcileRuntimeMaterialCleanup() async {
    try {
      runtimeMaterialChecks = await service.owner
          .reconcileCredentialMaterialCleanup();
      runtimeMaterialCleanupFailed = false;
    } catch (_) {
      runtimeMaterialCleanupFailed = true;
    }
    notifyListeners();
  }

  Future<void> _notify(String requestId) async {
    await _ready.future;
    if (quitting ||
        !service.owner.notificationsEnabled ||
        availability.notifications != NotificationAvailability.enabled) {
      return;
    }
    try {
      if (await platform.notifyNewRequest(requestId)) return;
    } on Object {
      /* Unavailable notification delivery must not lose a request. */
    }
    await _refreshAfterNotificationFailure();
  }

  Future<void> _refreshAfterNotificationFailure({
    bool markUnavailable = true,
  }) async {
    var current = DesktopAvailability(
      tray: availability.tray,
      notifications: NotificationAvailability.unavailable,
    );
    try {
      final actual = await platform.readAvailability();
      current = DesktopAvailability(
        tray: actual.tray,
        notifications:
            markUnavailable &&
                actual.notifications == NotificationAvailability.enabled
            ? NotificationAvailability.unavailable
            : actual.notifications,
      );
    } on Object {
      // Keep a delivery failure visible even when the status query also fails.
    }
    if (quitting) return;
    availability = current;
    notifyListeners();
  }

  Future<bool> testNotification() async {
    if (quitting ||
        availability.notifications != NotificationAvailability.enabled) {
      return false;
    }
    try {
      if (await platform.notifyTest()) return true;
    } catch (_) {
      /* Report the actual permission state when a test cannot be submitted. */
    }
    // A manual test can be retried when system permission remains enabled.
    await _refreshAfterNotificationFailure(markUnavailable: false);
    return false;
  }

  Future<void> enableNotifications() async {
    if (quitting) return;
    try {
      availability = await platform.requestNotificationPermission();
    } on Object {
      availability = DesktopAvailability(
        tray: availability.tray,
        notifications: NotificationAvailability.unavailable,
      );
    }
    notifyListeners();
  }

  Future<void> _refreshAvailability() async {
    DesktopAvailability current;
    try {
      current = await platform.readAvailability();
    } on Object {
      current = DesktopAvailability.unavailable;
    }
    if (quitting || _stopped) return;
    availability = current;
    notifyListeners();
  }

  Future<void> _resumeDesktop() async {
    try {
      // Wake/session events may arrive before native initialization replies.
      await _ready.future;
      if (quitting || _stopped) return;
      // Reconcile expired material immediately, in the same queue as periodic
      // maintenance. No new session, extended grant or repeated notification.
      await _maintain();
      if (quitting || _stopped) return;
      await _refreshAvailability();
    } finally {
      _resuming = null;
    }
  }

  Future<void> handleEvent(DesktopEvent event) async {
    if (_stopped) {
      // Native close interception can outlive failed-startup cleanup. This
      // runtime no longer owns data, but must keep the error window closable.
      if (event == DesktopEvent.closeWindow || event == DesktopEvent.quit) {
        await platform.terminate();
      } else if (event == DesktopEvent.openApprovals ||
          event == DesktopEvent.openSettings ||
          event == DesktopEvent.searchApprovals) {
        await platform.showWindow();
      }
      return;
    }
    if (event == DesktopEvent.quit) {
      await quit();
      // Native local control needs an explicit refusal, not an acknowledged
      // event whose audit writes are still unsaved. UI callers use quit().
      if (shutdownFailed) throw StateError('shutdown_failed');
      return;
    }
    if (quitting) return;
    switch (event) {
      case DesktopEvent.closeWindow:
        try {
          if (await platform.hideWindow()) return;
        } on Object {
          /* Keep the visible window reachable if the tray failed. */
        }
        availability = DesktopAvailability(
          tray: false,
          notifications: availability.notifications,
        );
        notifyListeners();
      case DesktopEvent.openApprovals:
        await platform.showWindow();
        openRequestId = platform.openedRequestId;
        openApprovalsRevision++;
        notifyListeners();
      case DesktopEvent.availabilityChanged:
        // Native code restores a hidden window before reporting entry failure.
        await _ready.future;
        if (quitting || _stopped) return;
        await _refreshAvailability();
      case DesktopEvent.resumed:
        // Wake and active-session notifications often arrive together.
        await (_resuming ??= _resumeDesktop());
      case DesktopEvent.openSettings:
        await _ready.future;
        if (quitting || _stopped) return;
        await platform.showWindow();
        if (quitting || _stopped) return;
        openSettingsRevision++;
        notifyListeners();
      case DesktopEvent.searchApprovals:
        await _ready.future;
        if (quitting || _stopped) return;
        await platform.showWindow();
        if (quitting || _stopped) return;
        searchApprovalsRevision++;
        notifyListeners();
      case DesktopEvent.quit:
        break;
    }
  }

  Future<void> quit() => _quit ??= _shutdown();

  /// Stops a partially started runtime as well as a running one. Failed audit
  /// writes keep the library open and are retried using this same owner.
  Future<void> stop() => _stop ??= _stopResources();
  Future<void> _stopResources() async {
    quitting = true;
    _maintenanceTimer?.cancel();
    if (!_ready.isCompleted) _ready.complete();
    notifyListeners();
    try {
      final navigation = _setNavigationEnabled(false);
      // close synchronously rejects capabilities, then waits for queued facts.
      // The database must stay open when those facts cannot yet be saved.
      await Future.wait([
        service.close(),
        closeServer(),
        navigation,
        _maintenance,
        if (_requests case final requests?) requests.cancel(),
      ]);
      await closeRepository();
      _stopped = true;
    } on Object {
      _stop = null;
      rethrow;
    }
  }

  Future<void> _shutdown() async {
    shutdownFailed = false;
    try {
      await stop();
      await platform.terminate();
    } on Object {
      shutdownFailed = true;
      quitting = false;
      _quit = null;
      try {
        await platform.showWindow();
      } on Object {
        /* Preserve unsaved facts. */
      }
      notifyListeners();
      return;
    }
  }
}
