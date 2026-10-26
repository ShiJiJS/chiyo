import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui.dart';
import 'mac_text_editing.dart';
import 'mac_text_field_accessibility.dart';

/// The native caption stays available until these controls have been installed.
/// Closing follows the existing native close event (including tray behavior).
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child, this.caption});
  final Widget child;
  final String? caption;
  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  static const _channel = MethodChannel('agent_info_manage/window');
  static _DesktopWindowFrameState? _listenerOwner;
  bool _enabled = false;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _listenerOwner = this;
      _channel.setMethodCallHandler((call) async {
        if (mounted && call.method == 'state') {
          setState(() => _maximized = call.arguments == true);
        }
      });
      unawaited(_enable());
    }
  }

  Future<void> _enable() async {
    try {
      final maximized = await _channel.invokeMethod<bool>('enableCustomFrame');
      if (mounted && maximized != null) {
        setState(() {
          _enabled = true;
          _maximized = maximized;
        });
      }
    } on PlatformException {
      // Keep the system caption if the host cannot install a custom frame.
    } on MissingPluginException {
      // Non-native previews and older runners keep their existing frame.
    }
  }

  Future<void> _command(String command) async {
    try {
      await _channel.invokeMethod<void>(command);
    } on PlatformException {
      // A closing native window can stop accepting commands.
    } on MissingPluginException {
      // Only the native Windows runner installs this channel.
    }
  }

  @override
  void dispose() {
    // Startup replaces the launcher with the ready app. The outgoing frame
    // must not clear a handler already installed by the incoming frame.
    if (identical(_listenerOwner, this)) {
      _channel.setMethodCallHandler(null);
      _listenerOwner = null;
    }
    super.dispose();
  }

  Widget _button(String label, IconData icon, String command) => SizedBox(
    width: 46,
    height: 34,
    child: TextButton(
      key: ValueKey('window-$command'),
      onPressed: () => _command(command),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        shape: const RoundedRectangleBorder(),
        foregroundColor: UiPalette.of(context).ink,
        overlayColor: command == 'close'
            ? Colors.red
            : UiPalette.of(context).muted,
      ),
      child: Tooltip(message: label, child: Icon(icon, size: 15)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      return MacTextFieldAccessibilityHost(
        child: MacTextEditingActions(child: widget.child),
      );
    }
    if (!_enabled) return widget.child;
    return Overlay.wrap(
      child: Column(
        // A route blocks semantics painted before it. Paint the workspace
        // first so its Navigator cannot hide the caption or its Tooltip anchor,
        // while keeping the caption visually above the workspace.
        verticalDirection: VerticalDirection.up,
        children: [
          Expanded(child: widget.child),
          Material(
            color: UiPalette.of(context).rail,
            child: SizedBox(
              height: 34,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      key: const ValueKey('window-drag'),
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => _command('drag'),
                      onDoubleTap: () => _command('toggleMaximize'),
                      child: widget.caption == null
                          ? const SizedBox.expand()
                          : Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.only(left: 14),
                              child: Text(
                                widget.caption!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: UiPalette.of(context).muted,
                                ),
                              ),
                            ),
                    ),
                  ),
                  _button('最小化', Icons.remove, 'minimize'),
                  _button(
                    _maximized ? '还原窗口' : '最大化',
                    _maximized ? Icons.filter_none : Icons.crop_square,
                    'toggleMaximize',
                  ),
                  _button('关闭窗口', Icons.close, 'close'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
