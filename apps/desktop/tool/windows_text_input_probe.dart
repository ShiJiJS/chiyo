// Synthetic native-input diagnostic. Never loads a connection or a library.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadWindowsDesktopFonts();
  runApp(const _InputProbe());
}

class _InputProbe extends StatefulWidget {
  const _InputProbe();
  @override
  State<_InputProbe> createState() => _InputProbeState();
}

class _InputProbeState extends State<_InputProbe> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _events = <String>[];
  var _shortcuts = 0;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_key);
  }

  void _changed() => setState(() {});
  bool _key(KeyEvent event) {
    setState(() {
      _events.add(
        '${event.runtimeType} ${event.logicalKey.debugName} '
        'ctrl=${HardwareKeyboard.instance.isControlPressed} '
        'shift=${HardwareKeyboard.instance.isShiftPressed}',
      );
      if (_events.length > 12) _events.removeAt(0);
    });
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: zhiyuTheme(Brightness.light),
    home: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          setState(() => _shortcuts++);
          _focus.requestFocus();
        },
      },
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Windows synthetic input diagnostic'),
              const Text('No NAS connection. Enter synthetic text only.'),
              DesktopTextField(
                controller: _text,
                focusNode: _focus,
                decoration: const InputDecoration(labelText: 'Synthetic input'),
              ),
              Text('Text: ${_text.text}'),
              Text('Composing: ${_text.value.composing}'),
              Text('Ctrl K callbacks: $_shortcuts'),
              Text(
                _events.join('\n'),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
