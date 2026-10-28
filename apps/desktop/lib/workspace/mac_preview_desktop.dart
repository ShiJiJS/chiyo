import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../desktop_scroll.dart';
import 'workspace_source.dart';

/// The preview runner exposes navigation and host appearance. No desktop service
/// is initialized to obtain menus, a title or a normal Cocoa quit action.
class MacPreviewDesktop {
  static const windowTitle = '知予 · 界面预览·示例数据';
  static const channel = MethodChannel('agent_info_manage/interface_preview');
  void Function(WorkspacePage page)? onNavigate;
  bool _navigationEnabled = true;
  final scrollbarStyle = ValueNotifier(DesktopScrollbarStyle.legacy);
  bool _disposed = false;
  bool _initialized = false;
  int _scrollbarRevision = -1;

  static DesktopScrollbarStyle _style(Object? value) => switch (value) {
    'overlay' => DesktopScrollbarStyle.overlay,
    'legacy' => DesktopScrollbarStyle.legacy,
    _ => throw StateError('Invalid native scrollbar appearance.'),
  };

  void _appearance(Object? style, Object? revision) {
    final next = _style(style);
    if (revision is! int || revision < 0) {
      throw StateError('Invalid native appearance revision.');
    }
    if (revision <= _scrollbarRevision) return;
    _scrollbarRevision = revision;
    scrollbarStyle.value = next;
  }

  Future<Map<String, Object?>> initialize() async {
    if (_disposed) throw StateError('The preview desktop is disposed.');
    channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      // Appearance can change while an unsaved editor freezes navigation.
      if (call.method == 'scrollbarStyleChanged') {
        final data = call.arguments;
        if (data is! Map) throw StateError('Invalid appearance event.');
        _appearance(data['style'], data['revision']);
        return;
      }
      if (!_initialized || !_navigationEnabled) return;
      switch (call.method) {
        case 'openSettings':
          onNavigate?.call(WorkspacePage.settings);
        case 'searchApprovals':
          onNavigate?.call(WorkspacePage.library);
        case 'open':
          onNavigate?.call(WorkspacePage.approvals);
      }
    });
    try {
      final state = await channel.invokeMapMethod<String, Object?>(
        'initialize',
      );
      if (_disposed) throw StateError('The preview desktop is disposed.');
      if (state?['isolated'] != true ||
          state?['productionServices'] != false ||
          state?['savedDirectories'] != false ||
          state?['title'] != windowTitle) {
        throw StateError('The native runner is not an isolated UI preview.');
      }
      // A newer appearance event may arrive before the initialize reply.
      _appearance(state?['scrollbarStyle'], state?['scrollbarRevision']);
      _initialized = true;
      return state!;
    } catch (_) {
      channel.setMethodCallHandler(null);
      rethrow;
    }
  }

  Future<void> setNavigationEnabled(bool enabled) {
    // An already queued native event must also respect the current Dart gate.
    _navigationEnabled = enabled;
    return channel.invokeMethod<void>('setNavigationEnabled', enabled);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _navigationEnabled = false;
    onNavigate = null;
    channel.setMethodCallHandler(null);
    scrollbarStyle.dispose();
  }
}
