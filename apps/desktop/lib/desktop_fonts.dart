import 'dart:io';
import 'package:flutter/services.dart';

String get desktopFontFamily => Platform.isMacOS ? 'Zhiyu System' : 'Segoe UI';
List<String> get desktopFontFallback => Platform.isMacOS
    ? const ['PingFang SC', 'sans-serif']
    : const ['Microsoft YaHei', 'Microsoft YaHei UI', 'sans-serif'];

/// System font paths are discovered locally, never copied into a distribution.
/// The returned profile is also used by local reference/capture tooling.
Future<Map<String, String>> loadDesktopFonts({
  bool requiredFiles = true,
}) async {
  if (!Platform.isMacOS) {
    if (!await loadWindowsDesktopFonts()) {
      throw StateError('Desktop reference fonts are unavailable.');
    }
    return {'platform': Platform.operatingSystem, 'family': desktopFontFamily};
  }
  var pingFang = File('/System/Library/Fonts/PingFang.ttc');
  if (!await pingFang.exists()) {
    final assets = Directory(
      '/System/Library/AssetsV2/com_apple_MobileAsset_Font8',
    );
    if (await assets.exists()) {
      await for (final asset in assets.list(followLinks: false)) {
        if (asset is! Directory) continue;
        final candidate = File('${asset.path}/AssetData/PingFang.ttc');
        if (await candidate.exists()) {
          pingFang = candidate;
          break;
        }
      }
    }
  }
  final files = {
    'Zhiyu System': '/System/Library/Fonts/SFNS.ttf',
    'PingFang SC': pingFang.path,
    'Menlo': '/System/Library/Fonts/Menlo.ttc',
  };
  final loaded = <String, String>{};
  for (final entry in files.entries) {
    try {
      final bytes = await File(entry.value).readAsBytes();
      await (FontLoader(
        entry.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      loaded[entry.key] = entry.value;
    } on FileSystemException {
      // Production can use Flutter's system fallback on an OS without these
      // exact files. Reference captures still require every declared face.
      if (requiredFiles) rethrow;
    }
  }
  return {'platform': Platform.operatingSystem, ...loaded};
}

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
