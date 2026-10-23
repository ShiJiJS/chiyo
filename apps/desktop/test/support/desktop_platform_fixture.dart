import 'package:info_desktop/desktop_runtime.dart';

class NativeDesktopFixture
    implements DesktopPlatform, DesktopNavigationPlatform {
  @override
  String? openedRequestId;
  Future<void> Function(DesktopEvent)? events;
  bool hidden = false;
  bool terminated = false;
  final navigationStates = <bool>[];
  final notices = <String>[];
  DesktopAvailability availability = const DesktopAvailability(
    tray: true,
    notifications: NotificationAvailability.enabled,
  );
  Future<void>? initialization;
  int permissionRequests = 0;
  bool deliveryAvailable = true;
  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  ) async {
    events = onEvent;
    await initialization;
    return availability;
  }

  @override
  Future<bool> hideWindow() async {
    hidden = availability.tray;
    return hidden;
  }

  @override
  Future<void> showWindow() async {
    hidden = false;
  }

  @override
  Future<bool> notifyNewRequest(String requestId) async {
    // The payload is an opaque routing ID, with no submitted content.
    notices.add('new_request');
    return deliveryAvailable;
  }

  @override
  Future<bool> notifyTest() async {
    notices.add('test');
    return deliveryAvailable;
  }

  @override
  Future<DesktopAvailability> requestNotificationPermission() async {
    permissionRequests++;
    return availability;
  }

  @override
  Future<DesktopAvailability> readAvailability() async => availability;
  @override
  Future<void> terminate() async {
    terminated = true;
  }

  @override
  Future<void> setNavigationEnabled(bool enabled) async {
    navigationStates.add(enabled);
  }
}
