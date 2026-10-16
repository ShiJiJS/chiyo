import 'package:info_desktop/desktop_runtime.dart';

class NativeDesktopFixture implements DesktopPlatform {
  Future<void> Function(DesktopEvent)? events;
  bool hidden = false;
  bool terminated = false;
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
  Future<bool> notifyNewRequest() async {
    // This native boundary accepts no user-supplied notification payload.
    notices.add('new_request');
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
}
