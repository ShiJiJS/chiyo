import 'mac_text_field_accessibility.dart';
import 'package:flutter/material.dart';
import 'ui_palette.dart';
import 'mac_secret_input.dart';
import 'anchored_surface.dart';
import 'prototype_ui.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'desktop_motion.dart';
import 'desktop_button.dart';
export 'desktop_button.dart';

// Labels stay outside the editable border, including after a value is entered.
class DesktopTextField extends StatelessWidget {
  const DesktopTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.maxLength,
    this.minLines,
    this.maxLines = 1,
    this.enabled,
    this.onChanged,
    this.keyboardType,
    this.obscureText = false,
    this.enableSuggestions = true,
    this.autocorrect = true,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final int? maxLength, minLines, maxLines;
  final bool? enabled;
  final bool obscureText;
  final bool enableSuggestions, autocorrect;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) => _FieldFrame(
    label: decoration.labelText,
    inputPurpose: usesNativeSecretEditor && obscureText
        ? null
        : decoration.labelText ?? decoration.hintText,
    child: usesNativeSecretEditor && obscureText
        ? MacSecretInput(
            controller: controller,
            focusNode: focusNode,
            decoration: _inside(decoration),
            maxLength: maxLength,
            enabled: enabled ?? true,
            onChanged: onChanged,
            label: decoration.labelText ?? '秘密内容',
            style: Theme.of(context).textTheme.bodyMedium,
          )
        : TextField(
            controller: controller,
            focusNode: focusNode,
            decoration: _inside(decoration),
            maxLength: maxLength,
            minLines: minLines,
            maxLines: maxLines,
            enabled: enabled,
            onChanged: onChanged,
            keyboardType: keyboardType,
            obscureText: obscureText,
            enableSuggestions: enableSuggestions,
            autocorrect: autocorrect,
            style: Theme.of(context).textTheme.bodyMedium,
            buildCounter: _counter,
          ),
  );
}

class DesktopTextFormField extends StatelessWidget {
  const DesktopTextFormField({
    super.key,
    this.initialValue,
    this.controller,
    this.decoration = const InputDecoration(),
    this.maxLength,
    this.minLines,
    this.maxLines = 1,
    this.enabled,
    this.onChanged,
    this.keyboardType,
  });
  final String? initialValue;
  final TextEditingController? controller;
  final InputDecoration decoration;
  final int? maxLength, minLines, maxLines;
  final bool? enabled;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) => _FieldFrame(
    label: decoration.labelText,
    inputPurpose: decoration.labelText ?? decoration.hintText,
    child: TextFormField(
      initialValue: initialValue,
      controller: controller,
      decoration: _inside(decoration),
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: keyboardType,
      style: Theme.of(context).textTheme.bodyMedium,
      buildCounter: _counter,
    ),
  );
}

InputDecoration _inside(InputDecoration source) => source.copyWith(
  // copyWith cannot clear a nullable label. An empty label leaves the visible
  // and semantic label in the persistent field frame instead.
  labelText: '',
  floatingLabelBehavior: FloatingLabelBehavior.always,
  alignLabelWithHint: false,
);

Widget? _counter(
  BuildContext context, {
  required int currentLength,
  required bool isFocused,
  required int? maxLength,
}) => maxLength != null && currentLength >= maxLength * .8
    ? Text(
        '$currentLength / $maxLength',
        style: Theme.of(context).textTheme.bodySmall,
      )
    : null;

class _FieldFrame extends StatelessWidget {
  const _FieldFrame({required this.child, this.label, this.inputPurpose});
  final String? label, inputPurpose;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final protected = label?.contains('需要授权') == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: protected
          ? const EdgeInsets.fromLTRB(14, 12, 14, 0)
          : EdgeInsets.zero,
      decoration: protected
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null) ...[
            ExcludeSemantics(
              child: Text(
                label!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (inputPurpose?.isNotEmpty == true)
            MacTextFieldAccessibility(label: inputPurpose!, child: child)
          else
            Semantics(label: label, child: child),
          if (protected) const SizedBox(height: 14),
        ],
      ),
    );
  }
}

// AnchoredSurface supplies one-sided desktop menus. Item identity
// and disabled state are retained from the existing owner-facing selectors.
class DesktopSelect<T> extends StatefulWidget {
  const DesktopSelect({
    super.key,
    this.value,
    this.initialValue,
    required this.items,
    required this.onChanged,
    this.hint,
    this.isExpanded = false,
    this.decoration,
    this.compact = false,
    this.quiet = false,
    this.triggerLabel,
    this.leading,
  });
  final T? value, initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final bool isExpanded;
  final InputDecoration? decoration;
  final bool compact, quiet;
  final Widget? triggerLabel, leading;
  @override
  State<DesktopSelect<T>> createState() => _DesktopSelectState<T>();
}

class _SelectedValue<T> {
  const _SelectedValue(this.value);
  final T? value;
}

class _DesktopSelectState<T> extends State<DesktopSelect<T>> {
  final _buttonFocus = FocusNode();
  final _popup = AnchoredSurfaceController();
  bool _open = false;
  T? get _selected => widget.value ?? widget.initialValue;
  @override
  void dispose() {
    final close = _popup.close;
    if (close != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    }
    _buttonFocus.dispose();
    super.dispose();
  }

  Future<void> _show(BuildContext triggerContext) async {
    if (_open || widget.onChanged == null || widget.items.isEmpty) return;
    setState(() => _open = true);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    var width = widget.compact ? 230.0 : 180.0;
    for (final item in widget.items) {
      if (item.child case Text(:final data?)) {
        final text = TextPainter(
          text: TextSpan(text: data, style: prototypeText(context, 13)),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        width = math.max(width, text.width + 75);
      }
    }
    final result = await showAnchoredSurface<_SelectedValue<T>>(
      triggerContext,
      controller: _popup,
      width: width.clamp(widget.compact ? 230 : 180, 520),
      alignToEnd: true,
      height: math.min(
        340 * scale,
        widget.items.length * (13 * 1.7 * scale + 18) +
            12 +
            (widget.items.length > 12 ? 20 * scale + 38 : 0),
      ),
      builder: (_) =>
          _DesktopOptions<T>(items: widget.items, selected: _selected),
    );
    if (!mounted) return;
    setState(() => _open = false);
    _buttonFocus.requestFocus();
    if (result != null) widget.onChanged?.call(result.value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final labelContent =
        widget.items.where((i) => i.value == _selected).firstOrNull?.child ??
        widget.hint ??
        const Text('请选择');
    // A compact trigger has one line; its menu retains the complete label.
    // Long directory paths/tags must not consume an entire workspace column.
    final label = DefaultTextStyle.merge(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: labelContent,
    );
    final control = Builder(
      builder: (triggerContext) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () {
            if (enabled) _show(triggerContext);
          },
        },
        child: widget.compact
            ? DesktopButton(
                tooltip: widget.triggerLabel == null && labelContent is Text
                    ? labelContent.data
                    : null,
                focusNode: _buttonFocus,
                onPressed: enabled
                    ? () => _open ? _popup.close?.call() : _show(triggerContext)
                    : null,
                kind: widget.quiet
                    ? DesktopButtonKind.quiet
                    : DesktopButtonKind.outline,
                fontSize: 13,
                leading: widget.leading,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                minimumSize: Size(0, widget.quiet ? 33 : 34.8),
                child:
                    widget.triggerLabel ??
                    Row(
                      mainAxisSize: widget.isExpanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      children: [
                        if (widget.isExpanded)
                          Expanded(child: label)
                        else
                          Flexible(child: label),
                        const SizedBox(width: 7),
                        const PrototypeSelectCaret(),
                      ],
                    ),
              )
            : OutlinedButton(
                focusNode: _buttonFocus,
                onPressed: enabled
                    ? () => _open ? _popup.close?.call() : _show(triggerContext)
                    : null,
                style: prototypeButton(
                  context,
                  size: 13,
                  foreground: UiPalette.of(context).ink,
                  background: UiPalette.of(context).paper,
                  side: BorderSide(
                    color: _open
                        ? UiPalette.of(context).accent
                        : UiPalette.of(context).line,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  radius: 5,
                ),
                child: Row(
                  mainAxisSize: widget.isExpanded
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  children: [
                    if (widget.isExpanded)
                      Expanded(child: label)
                    else
                      Flexible(child: label),
                    const SizedBox(width: 12),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                    ),
                  ],
                ),
              ),
      ),
    );
    return widget.decoration?.labelText == null
        ? control
        : _FieldFrame(label: widget.decoration!.labelText, child: control);
  }
}

class _DesktopOptions<T> extends StatefulWidget {
  const _DesktopOptions({required this.items, this.selected});
  final List<DropdownMenuItem<T>> items;
  final T? selected;
  @override
  State<_DesktopOptions<T>> createState() => _DesktopOptionsState<T>();
}

class _DesktopOptionsState<T> extends State<_DesktopOptions<T>> {
  String _query = '';
  final _searchFocus = FocusNode();
  bool _matches(DropdownMenuItem<T> item) =>
      _query.isEmpty ||
      (item.child is Text
              ? (item.child as Text).data ?? ''
              : item.value.toString())
          .toLowerCase()
          .contains(_query.toLowerCase());
  late final _nodes = [for (final _ in widget.items) FocusNode()];
  late int _focused = math.max(
    0,
    widget.items.indexWhere((i) => i.enabled && i.value == widget.selected),
  );
  final _keys = <int, GlobalKey>{};
  @override
  void initState() {
    super.initState();
    if (!widget.items[_focused].enabled) {
      _focused = widget.items.indexWhere((i) => i.enabled);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = _keys[_focused]?.currentContext;
      if (mounted && selectedContext != null) {
        Scrollable.ensureVisible(selectedContext, alignment: .5);
      }
      if (mounted && widget.items.length > 12) {
        _searchFocus.requestFocus();
      } else if (mounted && _focused >= 0) {
        _nodes[_focused].requestFocus();
      }
    });
  }

  void _step(int direction) {
    for (var i = 1; i <= widget.items.length; i++) {
      final next = (_focused + direction * i) % widget.items.length;
      if (widget.items[next].enabled && _matches(widget.items[next])) {
        setState(() => _focused = next);
        _nodes[next].requestFocus();
        final ctx = _keys[next]?.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .5);
        break;
      }
    }
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _step(1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _step(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Column(
      children: [
        if (widget.items.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            child: MacTextFieldAccessibility(
              label: '搜索选项',
              child: TextField(
                focusNode: _searchFocus,
                decoration: const InputDecoration(
                  hintText: '搜索选项',
                  prefixIcon: Icon(Icons.search, size: 16),
                ),
                onChanged: (value) => setState(() {
                  _query = value;
                }),
                onSubmitted: (_) {
                  final item = widget.items
                      .where((i) => i.enabled && _matches(i))
                      .firstOrNull;
                  if (item != null) {
                    Navigator.pop(context, _SelectedValue<T>(item.value));
                  }
                },
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            primary: false,
            padding: EdgeInsets.all(DesktopMotion.enabled(context) ? 5 : 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.items.any(_matches))
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('没有匹配的选项'),
                  ),
                for (final (index, item) in widget.items.indexed)
                  if (_matches(item))
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: DesktopMotion.enabled(context) ? 0 : 2,
                      ),
                      child: DesktopMotion.enabled(context)
                          ? DesktopButton(
                              key: _keys.putIfAbsent(index, () => GlobalKey()),
                              focusNode: _nodes[index],
                              kind: DesktopButtonKind.menu,
                              radius: 5,
                              selected: item.value == widget.selected,
                              fontSize: 13,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                              onPressed: item.enabled
                                  ? () => Navigator.pop(
                                      context,
                                      _SelectedValue<T>(item.value),
                                    )
                                  : null,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: DefaultTextStyle.merge(
                                      style: const TextStyle(
                                        height: 1.7,
                                        fontWeight: FontWeight.w400,
                                      ),
                                      child: item.child,
                                    ),
                                  ),
                                  if (item.value == widget.selected) ...[
                                    const SizedBox(width: 9),
                                    const Icon(Icons.check, size: 15),
                                  ],
                                ],
                              ),
                            )
                          : TextButton(
                              key: _keys.putIfAbsent(index, () => GlobalKey()),
                              focusNode: _nodes[index],
                              style: prototypeButton(
                                context,
                                size: 13,
                                foreground: UiPalette.of(context).ink,
                                background: item.value == widget.selected
                                    ? UiPalette.of(context).selected
                                    : null,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 9,
                                ),
                              ),
                              onPressed: item.enabled
                                  ? () => Navigator.pop(
                                      context,
                                      _SelectedValue<T>(item.value),
                                    )
                                  : null,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 18,
                                    child: item.value == widget.selected
                                        ? const Icon(Icons.check, size: 14)
                                        : null,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: item.child),
                                ],
                              ),
                            ),
                    ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class DesktopDialog extends StatelessWidget {
  const DesktopDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.width = 740,
    this.onClose,
    this.closeEnabled = true,
  });
  final Widget? title, content;
  final List<Widget>? actions;
  final double width;
  final VoidCallback? onClose;
  final bool closeEnabled;
  @override
  Widget build(BuildContext context) {
    if (DesktopMotion.enabled(context)) {
      final c = UiPalette.of(context);
      final viewport = MediaQuery.sizeOf(context);
      return Center(
        child: Container(
          width: math.min(width, viewport.width - 40),
          constraints: BoxConstraints(maxHeight: viewport.height - 70),
          decoration: BoxDecoration(
            color: c.paper,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .2),
                blurRadius: 70,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(28, 20, 20, 20),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.line)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: DefaultTextStyle(
                          style: Theme.of(context).textTheme.titleMedium!
                              .copyWith(
                                fontSize: 19,
                                fontWeight: FontWeight.w600,
                              ),
                          child: title ?? const SizedBox(),
                        ),
                      ),
                      Tooltip(
                        message: '关闭',
                        child: IconButton(
                          key: const ValueKey('desktop-dialog-close'),
                          onPressed: closeEnabled
                              ? onClose ??
                                    () => Navigator.of(context).maybePop()
                              : null,
                          icon: const Icon(Icons.close, size: 19),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    primary: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    child: content ?? const SizedBox(),
                  ),
                ),
                if (actions?.isNotEmpty ?? false)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 15,
                    ),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.line)),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 10,
                      children: actions!,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
      titlePadding: EdgeInsets.zero,
      title: title == null
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(24, 19, 24, 19),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: title,
            ),
      contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      content: content,
      actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      actions: actions,
    );
  }
}

/// Uses the shared modal surface with the approved opening motion. Callers
/// own form drafts and only close after their source reports successful save.
Future<T?> showDesktopDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  FocusNode? returnFocus,
}) async {
  Tooltip.dismissAllToolTips();
  final focus = returnFocus ?? FocusManager.instance.primaryFocus;
  final navigator = Navigator.of(context, rootNavigator: true);
  try {
    final route = RawDialogRoute<T>(
      barrierDismissible: barrierDismissible,
      barrierLabel: '关闭对话框',
      barrierColor: UiPalette.of(context).brightness == Brightness.dark
          ? const Color(0x8f080b12)
          : const Color(0x55162238),
      transitionDuration: DesktopMotion.duration(context, DesktopMotion.dialog),
      pageBuilder: (dialogContext, _, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(dialogContext).maybePop(),
        },
        child: builder(dialogContext),
      ),
      transitionBuilder: (_, animation, _, child) => AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (_, child) {
          final value = Curves.easeOut.transform(animation.value);
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 7 * (1 - value)),
              child: child,
            ),
          );
        },
      ),
    );
    final result = await navigator.push<T>(route);
    await route.completed;
    return result;
  } finally {
    if (focus?.context?.mounted ?? false) focus!.requestFocus();
  }
}
