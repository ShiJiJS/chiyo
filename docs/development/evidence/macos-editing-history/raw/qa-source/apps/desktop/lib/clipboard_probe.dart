import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui.dart';
import 'window_frame.dart';

const fixture = '中文 合成粘贴 Clipboard';
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Probe());
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  final editor = TextEditingController();
  static const clipboard = MethodChannel('qa/clipboard');
  String status = 'No clipboard changes';
  @override
  void initState() {
    super.initState();
    editor.addListener(() {
      final value = editor.value;
      debugPrint(
        'QA_VALUE ${jsonEncode({
          'length': value.text.length,
          'fixtureExact': value.text == fixture,
          'asciiExact': value.text == 'FlutterBaseline',
          'empty': value.text.isEmpty,
          'selection': [value.selection.baseOffset, value.selection.extentOffset],
          'composing': [value.composing.start, value.composing.end],
        })}',
      );
    });
  }

  Future<void> seed() async {
    await clipboard.invokeMethod<void>('seed');
    if (mounted) setState(() => status = 'Synthetic clipboard ready');
  }

  Future<void> restore() async {
    await clipboard.invokeMethod<void>('restore');
    if (mounted) setState(() => status = 'Previous clipboard restored');
  }

  Future<void> panel() async {
    const channel = MethodChannel('agent_info_manage/backup_files');
    final value = await channel.invokeMethod<String>(
      'informationFileOutput',
      'ClipboardPanelSynthetic.txt',
    );
    debugPrint('QA_PANEL cancelled=${value == null}');
    if (mounted) {
      setState(
        () => status = value == null
            ? 'Native panel cancelled'
            : 'Unexpected selection',
      );
    }
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: informationTheme(),
    builder: (context, child) => DesktopWindowFrame(child: child!),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            const Text('Synthetic history probe — no library or Keychain'),
            DesktopTextField(
              controller: editor,
              decoration: const InputDecoration(labelText: 'Synthetic editor'),
            ),
            TextButton(
              onPressed: seed,
              child: const Text('Seed synthetic clipboard'),
            ),
            TextButton(
              onPressed: restore,
              child: const Text('Restore previous clipboard'),
            ),
            TextButton(
              onPressed: panel,
              child: const Text('Open native save panel'),
            ),
            Text(status),
          ],
        ),
      ),
    ),
  );
}
