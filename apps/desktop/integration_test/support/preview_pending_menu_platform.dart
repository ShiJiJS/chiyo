import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import '../../test/support/desktop_platform_fixture.dart';

class PreviewPendingMenuPlatform extends NativeDesktopFixture
    implements DesktopPendingMenuPlatform {
  static const channel = MacPreviewDesktop.channel;
  Map<String, Object?> state = {};

  @override
  bool get supportsPendingMenu => true;

  @override
  void setPendingMenuHandler(Future<void> Function(String, Object?)? handler) {
    channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method.startsWith('pendingMenu')) {
                await handler(call.method, call.arguments);
              }
            },
    );
  }

  @override
  Future<void> updatePendingMenu(Map<String, Object?> state) async {
    await channel.invokeMethod<void>('updatePendingMenu', state);
    this.state = state;
  }

  Future<T?> native<T>(
    String action, [
    Map<String, Object?> values = const {},
  ]) =>
      channel.invokeMethod<T>('testPendingMenu', {'action': action, ...values});

  @override
  Future<bool> hideWindow() async =>
      hidden = await native<bool>('hideWindow') ?? false;

  @override
  Future<void> showWindow() async {
    await native<bool>('showWindow');
    await super.showWindow();
  }
}
