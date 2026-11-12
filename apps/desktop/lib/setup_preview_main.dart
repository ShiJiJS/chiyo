import 'dart:io';
import 'package:flutter/material.dart';
import 'desktop_fonts.dart';
import 'onboarding/setup_configuration.dart';
import 'onboarding/setup_preview_adapter.dart';
import 'workspace/mac_preview_desktop.dart';
import 'workspace/sample_workspace_source.dart';
import 'workspace/workspace_app.dart';

/// UI-only entry point. No production bootstrap, profiles, network, database,
/// Keychain, CLI registration or server initialization is reachable here.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadDesktopFonts(requiredFiles: false);
  final desktop = Platform.isMacOS ? MacPreviewDesktop() : null;
  await desktop?.initialize();
  runApp(SetupPreviewApp(desktop: desktop));
}

class SetupPreviewApp extends StatefulWidget {
  const SetupPreviewApp({super.key, this.desktop});
  final MacPreviewDesktop? desktop;

  @override
  State<SetupPreviewApp> createState() => _SetupPreviewAppState();
}

class _SetupPreviewAppState extends State<SetupPreviewApp> {
  final _draft = SetupPreviewDraft();
  final _source = SampleWorkspaceSource(
    fixtureJson:
        '{"records":[],"trash":[],"directories":[],"tags":[],"pending":0,"proposals":0}',
  )..setScenario(SampleWorkspaceScenario.empty);
  bool _entered = false;

  @override
  void dispose() {
    _draft.dispose();
    _source.dispose();
    widget.desktop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _entered
      ? WorkspaceApp(
          source: _source,
          sync: _draft,
          desktop: widget.desktop,
          windowTitle: MacPreviewDesktop.windowTitle,
          connectionBuilder: (context, onBack) =>
              ConnectionSettings(draft: _draft, onBack: onBack),
        )
      : InitialConnectionSetup(
          draft: _draft,
          onComplete: () => setState(() => _entered = true),
        );
}
