import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'window_frame.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SheetProbe());
}

class SheetProbe extends StatefulWidget {
  const SheetProbe({super.key});
  @override
  State<SheetProbe> createState() => _SheetProbeState();
}

class _SheetProbeState extends State<SheetProbe> {
  String secret = 'SyntheticSheet42';
  String status = 'No edit yet';
  final ordinary = TextEditingController(text: 'SyntheticPlain42');
  @override
  void dispose() {
    ordinary.dispose();
    super.dispose();
  }

  Future<void> edit() async {
    final before = secret;
    final result = await const MethodChannel(
      'qa/secret_sheet',
    ).invokeMethod<String>('edit', {'initial': secret});
    if (!mounted) return;
    setState(() {
      if (result != null) secret = result;
      status = result == null
          ? 'Cancelled; previous value retained'
          : 'Native value accepted';
    });
    debugPrint(
      'QA_SHEET_DART cancelled=${result == null} unchanged=${secret == before} updatedExact=${secret == 'SyntheticSheetUpdated42'}',
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (_, child) => DesktopWindowFrame(child: child!),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            const Text(
              'Synthetic native secret sheet; no Flutter secret editor',
            ),
            Text(secret.isEmpty ? 'Secret is empty' : 'Secret is set'),
            TextButton(
              onPressed: edit,
              child: const Text('Edit synthetic secret'),
            ),
            TextField(
              controller: ordinary,
              decoration: const InputDecoration(
                labelText: 'Ordinary synthetic',
              ),
            ),
            Text(status),
          ],
        ),
      ),
    ),
  );
}
