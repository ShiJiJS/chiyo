import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native menu actions carry only an action name; text stays in EditableText.
class MacTextEditingActions extends StatefulWidget {
  const MacTextEditingActions({super.key, required this.child});
  final Widget child;
  @override
  State<MacTextEditingActions> createState() => _MacTextEditingActionsState();
}

class _MacTextEditingActionsState extends State<MacTextEditingActions> {
  static const _channel = MethodChannel('agent_info_manage/text_editing');
  static _MacTextEditingActionsState? _owner;
  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      _owner = this;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'getEditingState') return _editingState();
        final Intent intent = switch (call.method) {
          'selectAll' => const SelectAllTextIntent(
            SelectionChangedCause.keyboard,
          ),
          'copy' => CopySelectionTextIntent.copy,
          'cut' => const CopySelectionTextIntent.cut(
            SelectionChangedCause.keyboard,
          ),
          'paste' => const PasteTextIntent(SelectionChangedCause.keyboard),
          'undo' => const UndoTextIntent(SelectionChangedCause.keyboard),
          'redo' => const RedoTextIntent(SelectionChangedCause.keyboard),
          'deleteSelection' => const DeleteCharacterIntent(forward: false),
          _ => throw MissingPluginException(),
        };
        final context = FocusManager.instance.primaryFocus?.context;
        if (!mounted || context == null) return false;
        final editor = context.widget is EditableText
            ? context.widget as EditableText
            : context.findAncestorWidgetOfExactType<EditableText>();
        if (editor == null ||
            (editor.readOnly &&
                (intent is UndoTextIntent || intent is RedoTextIntent))) {
          return false;
        }
        if (call.method == 'deleteSelection' &&
            (editor.readOnly ||
                !editor.selectionEnabled ||
                !editor.controller.selection.isValid ||
                editor.controller.selection.isCollapsed)) {
          return false;
        }
        final action = Actions.maybeFind(context, intent: intent);
        if (action == null || !action.isEnabled(intent)) return false;
        Actions.invoke(context, intent);
        return true;
      });
    }
  }

  /// Menu validation needs booleans only, never editor or clipboard contents.
  Future<Map<String, bool>> _editingState() async {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    final state = context?.findAncestorStateOfType<EditableTextState>();
    if (!mounted || state == null) return {};
    final editor = state.widget;
    var pasteable = false;
    if (!editor.readOnly && editor.selectionEnabled) {
      try {
        pasteable = await Clipboard.hasStrings();
      } on PlatformException {
        // An unavailable clipboard must not enable Paste.
      }
    }
    if (!mounted ||
        !state.mounted ||
        !identical(_owner, this) ||
        !identical(FocusManager.instance.primaryFocus, focus)) {
      return {};
    }
    // Read current state after the asynchronous clipboard availability query.
    final current = state.widget;
    final value = current.controller.value;
    final selected = value.selection.isValid && !value.selection.isCollapsed;
    final selectable = current.selectionEnabled;
    final history = UndoManager.client;
    return {
      'copy': selectable && selected && !current.obscureText,
      'deleteSelection': selectable && selected && !current.readOnly,
      'cut':
          selectable && selected && !current.obscureText && !current.readOnly,
      'paste':
          selectable &&
          !current.readOnly &&
          value.selection.isValid &&
          pasteable,
      'selectAll':
          selectable &&
          value.text.isNotEmpty &&
          !(value.selection.start == 0 &&
              value.selection.end == value.text.length),
      'undo': !current.readOnly && (history?.canUndo ?? false),
      'redo': !current.readOnly && (history?.canRedo ?? false),
    };
  }

  @override
  void dispose() {
    if (identical(_owner, this)) {
      _channel.setMethodCallHandler(null);
      _owner = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
