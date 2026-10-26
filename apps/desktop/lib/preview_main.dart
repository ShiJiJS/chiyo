import 'package:flutter/material.dart';
import 'dart:io';
import 'workspace/preview_workspace.dart';
import 'workspace/mac_preview_desktop.dart';
import 'desktop_fonts.dart';

/// Separate entry point: no production launcher, database, local server,
/// notifications, hooks or credential execution is initialized.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadDesktopFonts();
  final desktop = Platform.isMacOS ? MacPreviewDesktop() : null;
  await desktop?.initialize();
  runApp(PreviewWorkspace(desktop: desktop));
}
