import 'package:flutter/material.dart';
import 'workspace/preview_workspace.dart';
import 'desktop_fonts.dart';

/// Separate entry point: no production launcher, database, local server,
/// notifications, hooks or credential execution is initialized.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadWindowsDesktopFonts();
  runApp(const PreviewWorkspace());
}
