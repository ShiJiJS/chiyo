import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';

enum DesktopEvent { closeWindow, openApprovals, quit, availabilityChanged }

enum NotificationAvailability { enabled, notEnabled, denied, unavailable }

class DesktopAvailability {
  const DesktopAvailability({required this.tray, required this.notifications});
  final bool tray;
  final NotificationAvailability notifications;
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

class NativeDesktopPlatform implements DesktopPlatform {
  @override
  String? openedRequestId;
  static const _channel = MethodChannel('agent_info_manage/desktop');
  DesktopAvailability _decode(Object? raw) {
    if (raw is! Map) return DesktopAvailability.unavailable;
    return DesktopAvailability(
      tray: raw['tray'] == true,
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
        'quit' => DesktopEvent.quit,
        'availability' => DesktopEvent.availabilityChanged,
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
  Future<void> terminate() => _channel.invokeMethod<void>('terminate');
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
  String? openRequestId;
  bool quitting = false;
  bool shutdownFailed = false;
  StreamSubscription<String>? _requests;
  Timer? _maintenanceTimer;
  Future<void> _maintenance = Future.value();
  bool recycleCleanupFailed = false;
  bool revisionCleanupFailed = false;
  bool attachmentCleanupFailed = false;
  bool credentialCleanupFailed = false;
  bool runtimeMaterialCleanupFailed = false;
  int runtimeMaterialChecks = 0;
  Future<void>? _quit;
  Future<void>? _stop;
  bool _stopped = false;
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
    _ready.complete();
    notifyListeners();
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
    try {
      await service.owner.purgeInformationAttachments();
      attachmentCleanupFailed = false;
    } catch (_) {
      attachmentCleanupFailed = true;
    }
    await reconcileRuntimeMaterialCleanup();
    try {
      await service.owner.pruneCredentialUseHistory();
    } catch (_) {
      credentialCleanupFailed = true;
    }
    notifyListeners();
  });
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
    availability = DesktopAvailability(
      tray: availability.tray,
      notifications: NotificationAvailability.unavailable,
    );
    notifyListeners();
  }

  Future<bool> testNotification() async {
    if (quitting ||
        availability.notifications != NotificationAvailability.enabled) {
      return false;
    }
    try {
      return await platform.notifyTest();
    } catch (_) {
      return false;
    }
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

  Future<void> handleEvent(DesktopEvent event) async {
    if (_stopped) {
      // Native close interception can outlive failed-startup cleanup. This
      // runtime no longer owns data, but must keep the error window closable.
      if (event == DesktopEvent.closeWindow || event == DesktopEvent.quit) {
        await platform.terminate();
      } else if (event == DesktopEvent.openApprovals) {
        await platform.showWindow();
      }
      return;
    }
    if (event == DesktopEvent.quit) {
      await quit();
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
        try {
          availability = await platform.readAvailability();
        } on Object {
          availability = DesktopAvailability.unavailable;
        }
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
      // close synchronously rejects capabilities, then waits for queued facts.
      // The database must stay open when those facts cannot yet be saved.
      await Future.wait([
        service.close(),
        closeServer(),
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
