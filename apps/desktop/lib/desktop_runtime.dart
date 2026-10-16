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

/// Owner-process-only native boundary. Notification arguments are deliberately
/// absent: no submitted text or authorization material can cross this boundary.
abstract interface class DesktopPlatform {
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  );
  Future<bool> hideWindow();
  Future<void> showWindow();
  Future<bool> notifyNewRequest();
  Future<DesktopAvailability> readAvailability();
  Future<DesktopAvailability> requestNotificationPermission();
  Future<void> terminate();
}

class NativeDesktopPlatform implements DesktopPlatform {
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
  Future<bool> notifyNewRequest() async =>
      await _channel.invokeMethod<bool>('notify') ?? false;
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
  bool quitting = false;
  bool shutdownFailed = false;
  StreamSubscription<String>? _requests;
  Timer? _maintenanceTimer;
  Future<void> _maintenance = Future.value();
  bool recycleCleanupFailed = false;
  Future<void>? _quit;
  final _ready = Completer<void>();

  Future<void> start() async {
    await _maintain();
    _maintenanceTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_maintain());
    });
    _requests = service.owner.requestSubmitted.listen((_) {
      unawaited(_notify());
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
    notifyListeners();
  });

  Future<void> _notify() async {
    await _ready.future;
    if (quitting ||
        availability.notifications != NotificationAvailability.enabled) {
      return;
    }
    try {
      if (await platform.notifyNewRequest()) return;
    } on Object {
      /* Unavailable notification delivery must not lose a request. */
    }
    availability = DesktopAvailability(
      tray: availability.tray,
      notifications: NotificationAvailability.unavailable,
    );
    notifyListeners();
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
  Future<void> _shutdown() async {
    quitting = true;
    _maintenanceTimer?.cancel();
    notifyListeners();
    try {
      // close synchronously rejects capabilities, then waits for queued facts.
      // The database must stay open when those facts cannot yet be saved.
      await Future.wait([service.close(), closeServer(), _maintenance]);
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
    await _requests?.cancel();
    await closeRepository();
    await platform.terminate();
  }
}
