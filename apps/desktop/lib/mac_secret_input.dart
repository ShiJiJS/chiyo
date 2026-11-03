import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get usesNativeSecretEditor =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Secret values stay out of Flutter's editable accessibility nodes on macOS.
class MacSecretInput extends StatefulWidget {
  const MacSecretInput({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.style,
    this.enabled = true,
    this.maxLength,
    this.onChanged,
    this.label = '凭据内容',
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextStyle? style;
  final bool enabled;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final String label;
  @override
  State<MacSecretInput> createState() => _MacSecretInputState();
}

class _MacSecretInputState extends State<MacSecretInput> {
  static const _channel = MethodChannel('agent_info_manage/secret_editor');
  static int _nextRequest = 0;
  late TextEditingController _controller;
  late FocusNode _focus;
  String? _request;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _controller.addListener(_changed);
    _focus = widget.focusNode ?? FocusNode(debugLabel: 'Mac secret input');
    _focus.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _cancel(String request) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'requestId': request});
    } on PlatformException {
      // A terminating native window can already have removed its handler.
    } on MissingPluginException {
      // The controller may be disposed after the native application exits.
    }
  }

  @override
  void didUpdateWidget(MacSecretInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (_request case final request?) _cancel(request);
      _controller.removeListener(_changed);
      if (oldWidget.controller == null) _controller.dispose();
      _controller = widget.controller ?? TextEditingController();
      _controller.addListener(_changed);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focus.removeListener(_changed);
      if (oldWidget.focusNode == null) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode(debugLabel: 'Mac secret input');
      _focus.addListener(_changed);
    }
    if (!widget.enabled && _request != null) _cancel(_request!);
  }

  Future<void> _edit() async {
    if (_busy || !widget.enabled) return;
    final controller = _controller;
    final initial = controller.text;
    final request = 'secret-${_nextRequest++}';
    _request = request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await _channel.invokeMethod<String>('edit', {
        'requestId': request,
        'title': widget.label,
        'initial': initial,
        'maxLength': widget.maxLength,
      });
      if (!mounted ||
          !widget.enabled ||
          !identical(controller, _controller) ||
          controller.text != initial ||
          value == null) {
        return;
      }
      if (value.contains('\u0000') ||
          utf8.encode(value).length > 65536 ||
          (widget.maxLength != null &&
              widget.maxLength! > 0 &&
              value.characters.length > widget.maxLength!)) {
        setState(() => _error = '内容不符合长度要求，请重新编辑');
        return;
      }
      if (value != initial) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        widget.onChanged?.call(value);
      }
    } on PlatformException {
      if (mounted) setState(() => _error = '无法编辑，请重试');
    } on MissingPluginException {
      if (mounted) setState(() => _error = '安全编辑器不可用，请重新打开应用');
    } finally {
      _request = null;
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.enabled && !_busy) _focus.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    if (_request case final request?) _cancel(request);
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    _focus.removeListener(_changed);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = _controller.text.isNotEmpty;
    return InputDecorator(
      decoration: widget.decoration.copyWith(
        enabled: widget.enabled,
        errorText: _error ?? widget.decoration.errorText,
      ),
      isEmpty: false,
      isFocused: _focus.hasFocus,
      child: Row(
        children: [
          Expanded(
            child: Text(
              _busy
                  ? '正在编辑…'
                  : filled
                  ? '已填写'
                  : '未填写',
              style: widget.style ?? Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            focusNode: _focus,
            onPressed: widget.enabled && !_busy ? _edit : null,
            child: Text(filled ? '修改' : '填写'),
          ),
        ],
      ),
    );
  }
}
