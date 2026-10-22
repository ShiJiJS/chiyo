import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'window_frame.dart';

const bridgeEnabled = true;
Object? qaSemanticsHandle;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  qaSemanticsHandle = WidgetsBinding.instance.ensureSemantics();
  runApp(const Probe());
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  final secure = TextEditingController(text: 'SyntheticSecret42');
  final plain = TextEditingController(text: 'SyntheticPlain42');
  final toggled = TextEditingController(text: 'SyntheticToggle42');
  bool obscure = false;
  MethodChannel? nativeChannel;
  String status = 'No file saved';
  @override
  void initState() {
    super.initState();
    for (final pair in [
      (secure, 'secure'),
      (plain, 'plain'),
      (toggled, 'toggle'),
    ]) {
      pair.$1.addListener(() {
        final value = pair.$1.value;
        debugPrint(
          'QA_AX ${jsonEncode({
            'field': pair.$2,
            'secureKnownExact': secure.text == 'SyntheticSecret42',
            'toggleKnownExact': toggled.text == 'SyntheticToggle42',
            'length': value.text.length,
            'selection': [value.selection.baseOffset, value.selection.extentOffset],
          })}',
        );
      });
    }
  }

  Future<void> panel() async {
    const channel = MethodChannel('agent_info_manage/backup_files');
    final result = await channel.invokeMethod<String>(
      'informationFileOutput',
      'SyntheticFlutterAX.txt',
    );
    debugPrint('QA_AX panelCancelled=${result == null}');
    if (mounted) {
      setState(
        () => status = result == null
            ? 'Native panel cancelled'
            : 'Unexpected selected path',
      );
    }
  }

  @override
  void dispose() {
    secure.dispose();
    plain.dispose();
    toggled.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (_, child) =>
        bridgeEnabled ? DesktopWindowFrame(child: child!) : child!,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Text('Synthetic Flutter AX control; menu bridge: $bridgeEnabled'),
            const Text('Native NSSecureTextField embedded in Flutter'),
            SizedBox(
              height: 42,
              child: AppKitView(
                viewType: 'qa/native_secure_ax',
                onPlatformViewCreated: (id) {
                  final channel = MethodChannel('qa/secure_view/$id');
                  nativeChannel = channel;
                  channel.setMethodCallHandler((call) async {
                    if (call.method == 'changed') {
                      final value = call.arguments as String;
                      debugPrint(
                        'QA_EMBEDDED_DART length=${value.length} replacementExact=${value == 'SyntheticReplacement42'}',
                      );
                    }
                    return null;
                  });
                },
              ),
            ),
            TextField(
              controller: secure,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Always obscured synthetic',
              ),
            ),
            TextField(
              controller: plain,
              decoration: const InputDecoration(
                labelText: 'Ordinary synthetic',
              ),
            ),
            TextField(
              controller: toggled,
              obscureText: obscure,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Toggle synthetic'),
            ),
            TextButton(
              onPressed: () => setState(() => obscure = !obscure),
              child: Text('Toggle obscured: $obscure'),
            ),
            TextButton(
              onPressed: panel,
              child: const Text('Open synthetic save panel'),
            ),
            TextButton(
              onPressed: () async {
                await nativeChannel?.invokeMethod<void>('setSynthetic');
              },
              child: const Text('Replace embedded with synthetic fixture'),
            ),
            TextButton(
              onPressed: () async {
                await const MethodChannel(
                  'qa/native_ax',
                ).invokeMethod<void>('inspect');
              },
              child: const Text('Inspect owned native AX booleans'),
            ),
            Text(status),
          ],
        ),
      ),
    ),
  );
}
