import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_dialogs.dart';
import 'credential_management.dart';
import 'mac_secret_input.dart';
import 'ui.dart';
import 'window_frame.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FocusManager.instance.addListener(() {
    final focus = FocusManager.instance.primaryFocus;
    debugPrint(
      'QA_FOCUS secretButton=${focus?.context?.findAncestorWidgetOfExactType<MacSecretInput>() != null} textEditor=${focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null}',
    );
  });
  AppLifecycleListener(
    onStateChange: (state) => debugPrint('QA_LIFECYCLE $state'),
  );
  runApp(const Probe());
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  final repository = MemoryInformationRepository();
  late final service = InformationService(repository: repository);
  final limited = TextEditingController(text: 'a');
  String summary = 'No credentials saved';
  void inspect() {
    final items = service.owner.credentials;
    final version = items.isEmpty ? 0 : items.single.version;
    final material = repository.credentialMaterials
        .where((m) => m.version == version)
        .firstOrNull;
    final text = material == null ? '' : utf8.decode(material.bytes);
    debugPrint(
      'QA_SAVED count=${items.length} version=$version createExact=${text == 'SyntheticCreate42'} rotateExact=${text == 'SyntheticRotate42'}',
    );
    if (mounted) {
      setState(
        () => summary = 'Saved credentials: ${items.length}; version: $version',
      );
    }
  }

  @override
  void initState() {
    super.initState();
    limited.addListener(
      () => debugPrint(
        'QA_LIMIT unicodeExact=${limited.text == '👩🏽‍💻é'} empty=${limited.text.isEmpty}',
      ),
    );
  }

  @override
  void dispose() {
    limited.dispose();
    service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: informationTheme(),
    builder: (_, child) => DesktopWindowFrame(child: child!),
    home: Builder(
      builder: (context) => Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Text(
                'Mac secret entry acceptance — synthetic memory repository',
              ),
              TextButton(
                onPressed: () async {
                  await showDialog<void>(
                    context: context,
                    builder: (_) => CredentialEditor(owner: service.owner),
                  );
                  inspect();
                },
                child: const Text('新建合成凭据'),
              ),
              TextButton(
                onPressed: () async {
                  if (service.owner.credentials.isNotEmpty) {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => CredentialManagement(
                        owner: service.owner,
                        credential: service.owner.credentials.single,
                        action: 'rotate',
                      ),
                    );
                    inspect();
                  }
                },
                child: const Text('轮换合成凭据'),
              ),
              MacSecretInput(
                controller: limited,
                label: '两字符边界测试',
                maxLength: 2,
              ),
              TextButton(
                onPressed: () async {
                  const desktop = MethodChannel('agent_info_manage/desktop');
                  desktop.setMethodCallHandler((call) async {
                    if (call.method == 'quit') {
                      debugPrint('QA_QUIT forwarded');
                      await service.close();
                      await desktop.invokeMethod<void>('terminate');
                    }
                    return null;
                  });
                  await desktop.invokeMethod<Object?>('initialize');
                  debugPrint('QA_DESKTOP initialized');
                },
                child: const Text('Prepare full-quit test'),
              ),
              Text(summary),
            ],
          ),
        ),
      ),
    ),
  );
}
