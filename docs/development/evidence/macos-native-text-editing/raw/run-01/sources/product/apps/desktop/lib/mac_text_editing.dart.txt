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
        if (call.method != 'selectAll') throw MissingPluginException();
        final context = FocusManager.instance.primaryFocus?.context;
        if (!mounted ||
            context == null ||
            (context.widget is! EditableText &&
                context.findAncestorWidgetOfExactType<EditableText>() ==
                    null)) {
          return false;
        }
        const intent = SelectAllTextIntent(SelectionChangedCause.keyboard);
        final action = Actions.maybeFind<SelectAllTextIntent>(context);
        if (action == null || !action.isEnabled(intent)) return false;
        Actions.invoke(context, intent);
        return true;
      });
    }
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
