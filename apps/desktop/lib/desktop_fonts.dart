import 'dart:io';
import 'package:flutter/services.dart';

/// Uses the machine's installed fonts, without shipping Windows font files.
/// Explicit registration also makes native Flutter and reference captures use
/// the same CJK face rather than an engine-selected fallback such as SimSun.
Future<bool> loadWindowsDesktopFonts() async {
  if (!Platform.isWindows) return false;
  final windows = Platform.environment['WINDIR'];
  if (windows == null) return false;
  var complete = true;
  for (final family in {
    'Segoe UI': ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf'],
    'Microsoft YaHei': ['msyh.ttc', 'msyhbd.ttc'],
  }.entries) {
    try {
      final loader = FontLoader(family.key);
      for (final file in family.value) {
        final bytes = await File('$windows/Fonts/$file').readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    } on FileSystemException {
      complete = false;
    }
  }
  return complete;
}
