import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Labels stay outside the editable border, including after a value is entered.
class DesktopTextField extends StatelessWidget {
  const DesktopTextField({
    super.key,
    this.controller,
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
    child: TextField(
      controller: controller,
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
  floatingLabelBehavior: FloatingLabelBehavior.never,
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
  const _FieldFrame({required this.child, this.label});
  final String? label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Semantics(
            label: label,
            child: ExcludeSemantics(
              child: Text(
                label!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
        Semantics(label: label, child: child),
      ],
    ),
  );
}

// MenuAnchor supplies desktop pointer and keyboard navigation. Item identity
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
  });
  final T? value, initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final bool isExpanded;
  final InputDecoration? decoration;
  @override
  State<DesktopSelect<T>> createState() => _DesktopSelectState<T>();
}

class _DesktopSelectState<T> extends State<DesktopSelect<T>> {
  final _menu = MenuController();
  final _buttonFocus = FocusNode();
  // Existing forms own their draft; persisted settings update only on success.
  T? get _selected => widget.value ?? widget.initialValue;

  @override
  void dispose() {
    _buttonFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final focusItem =
        widget.items
            .where((item) => item.enabled && item.value == _selected)
            .firstOrNull ??
        widget.items.where((item) => item.enabled).firstOrNull;
    final label =
        widget.items
            .where((item) => item.value == _selected)
            .firstOrNull
            ?.child ??
        widget.hint ??
        const Text('请选择');
    final control = MenuAnchor(
      controller: _menu,
      childFocusNode: _buttonFocus,
      consumeOutsideTap: true,
      menuChildren: [
        for (final item in widget.items)
          MenuItemButton(
            autofocus: identical(item, focusItem),
            onPressed: !enabled || !item.enabled
                ? null
                : () {
                    widget.onChanged!(item.value);
                  },
            leadingIcon: item.value == _selected
                ? const Icon(Icons.check, size: 14)
                : const SizedBox(width: 14),
            child: item.child,
          ),
      ],
      builder: (context, controller, child) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () {
            if (enabled) controller.open();
          },
        },
        child: OutlinedButton(
          focusNode: _buttonFocus,
          onPressed: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          ),
          child: Row(
            mainAxisSize: widget.isExpanded
                ? MainAxisSize.max
                : MainAxisSize.min,
            children: [
              if (widget.isExpanded) Expanded(child: label) else label,
              const SizedBox(width: 18),
              const Icon(Icons.expand_more, size: 16),
            ],
          ),
        ),
      ),
    );
    return widget.decoration == null
        ? control
        : _FieldFrame(label: widget.decoration!.labelText, child: control);
  }
}

class DesktopDialog extends StatelessWidget {
  const DesktopDialog({super.key, this.title, this.content, this.actions});
  final Widget? title, content;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => AlertDialog(
    titlePadding: EdgeInsets.zero,
    title: title == null
        ? null
        : Container(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: title,
          ),
    contentPadding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
    content: content,
    actionsPadding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
    actions: actions,
  );
}
