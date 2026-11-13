import 'dart:io';

/// Resolve an installed browser helper internally. Agent business input never
/// selects an executable; this does not inspect profiles or start the browser.
Future<String?> findInstalledEgoBrowser({
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final candidates = <String>[];
  final name = Platform.isWindows ? 'ego-browser.exe' : 'ego-browser';
  if (Platform.isMacOS) {
    var home = env['HOME'];
    const container = '/Library/Containers/com.example.infoDesktop/Data';
    if (home != null && home.endsWith(container)) {
      home = home.substring(0, home.length - container.length);
    }
    if (home != null && Directory(home).isAbsolute) {
      candidates.add('$home/.local/bin/$name');
    }
  }
  final path = env['PATH'] ?? env['Path'] ?? '';
  for (final folder in path.split(Platform.isWindows ? ';' : ':')) {
    if (folder.isNotEmpty && Directory(folder).isAbsolute) {
      candidates.add('$folder/$name');
    }
  }
  for (final path in candidates) {
    try {
      final file = File(path);
      if (await FileSystemEntity.type(file.path) != FileSystemEntityType.file) {
        continue;
      }
      final resolved = File(await file.resolveSymbolicLinks());
      if (!Platform.isWindows && (await resolved.stat()).mode & 0x49 == 0) {
        continue;
      }
      return resolved.path;
    } on Object {
      // An unavailable optional helper does not substitute another target.
    }
  }
  return null;
}
