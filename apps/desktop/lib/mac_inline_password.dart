import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An inline AppKit secure field. Masked input has no Flutter editable value.
/// The existing trusted Host controller remains the sole Dart draft owner.
class MacInlinePassword extends StatefulWidget {
  const MacInlinePassword({
    super.key,
    required this.controller,
    required this.enabled,
    required this.label,
    this.maxLength,
    this.obscureText = true,
    this.onChanged,
    this.decoration = const InputDecoration(),
  });
  final TextEditingController controller;
  final bool enabled;
  final String label;
  final int? maxLength;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final InputDecoration decoration;
  @override
  State<MacInlinePassword> createState() => _MacInlinePasswordState();
}

class _MacInlinePasswordState extends State<MacInlinePassword> {
  MethodChannel? _channel;
  bool _receiving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  Map<String, Object?> get _configuration => {
    'value': widget.controller.text,
    'enabled': widget.enabled,
    'obscured': widget.obscureText,
    'label': widget.label,
    'maxLength': widget.maxLength,
    'fontSize': MediaQuery.textScalerOf(
      context,
    ).scale(Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14),
    'dark': Theme.of(context).brightness == Brightness.dark,
  };
  Future<void> _send() async {
    final channel = _channel;
    if (channel == null || !mounted) return;
    try {
      await channel.invokeMethod<void>('update', _configuration);
    } on PlatformException {
      if (mounted) setState(() => _error = '密码输入暂不可用，请重新打开提案。');
    } on MissingPluginException {
      if (mounted) setState(() => _error = '密码输入暂不可用，请重新打开应用。');
    }
  }

  void _changed() {
    if (!_receiving) unawaited(_send());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_send());
  }

  @override
  void didUpdateWidget(MacInlinePassword oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    unawaited(_send());
  }

  void _created(int id) {
    final channel = MethodChannel('agent_info_manage/inline_password/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'changed' ||
          !mounted ||
          !widget.enabled ||
          call.arguments is! String) {
        return;
      }
      final value = call.arguments as String;
      if (value.contains('\u0000') ||
          utf8.encode(value).length > 65536 ||
          (widget.maxLength != null &&
              widget.maxLength! > 0 &&
              value.characters.length > widget.maxLength!)) {
        return;
      }
      _receiving = true;
      widget.controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      _receiving = false;
      widget.onChanged?.call(value);
    });
    unawaited(_send());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: widget.decoration.copyWith(
      enabled: widget.enabled,
      errorText: _error,
    ),
    isEmpty: false,
    child: SizedBox(
      height: MediaQuery.textScalerOf(context).scale(28),
      child: AppKitView(
        viewType: 'agent_info_manage/inline_password',
        creationParams: _configuration,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      ),
    ),
  );
}
