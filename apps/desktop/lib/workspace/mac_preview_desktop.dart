import 'package:flutter/services.dart';
import 'workspace_source.dart';

/// The preview runner only exposes navigation. No production desktop service
/// is initialized to obtain menus, a title or a normal Cocoa quit action.
class MacPreviewDesktop {
  static const windowTitle = '知予 · 界面预览·示例数据';
  static const channel = MethodChannel('agent_info_manage/interface_preview');
  void Function(WorkspacePage page)? onNavigate;
  bool _navigationEnabled = true;

  Future<Map<String, Object?>> initialize() async {
    final state = await channel.invokeMapMethod<String, Object?>('initialize');
    if (state?['isolated'] != true ||
        state?['productionServices'] != false ||
        state?['savedDirectories'] != false ||
        state?['title'] != windowTitle) {
      throw StateError('The native runner is not an isolated UI preview.');
    }
    channel.setMethodCallHandler((call) async {
      if (!_navigationEnabled) return;
      switch (call.method) {
        case 'openSettings':
          onNavigate?.call(WorkspacePage.settings);
        case 'searchApprovals':
          onNavigate?.call(WorkspacePage.library);
        case 'open':
          onNavigate?.call(WorkspacePage.approvals);
      }
    });
    return state!;
  }

  Future<void> setNavigationEnabled(bool enabled) {
    // An already queued native event must also respect the current Dart gate.
    _navigationEnabled = enabled;
    return channel.invokeMethod<void>('setNavigationEnabled', enabled);
  }

  void dispose() {
    _navigationEnabled = false;
    onNavigate = null;
    channel.setMethodCallHandler(null);
  }
}
